#
# Cookbook Name:: mysql
# Recipe:: server_galera
#
# Copyright 2012, AT&T Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

include_recipe "mysql::client"

if Chef::Config[:solo]
  missing_attrs = %w{
    server_debian_password server_root_password server_repl_password
  }.select do |attr|
    node["mysql"][attr].nil?
  end.map { |attr| "node['mysql']['#{attr}']" }

  if !missing_attrs.empty? or node["wsrep"]["password"].nil?
    Chef::Application.fatal!([
        "You must set #{missing_attrs.join(', ')} in chef-solo mode.",
        "For more information, see https://github.com/opscode-cookbooks/mysql#chef-solo-note"
      ].join(' '))
  end
else
  # generate all passwords
  node.set_unless['mysql']['server_debian_password'] = secure_password
  node.set_unless['mysql']['server_root_password']   = secure_password
  node.set_unless['mysql']['server_repl_password']   = secure_password
  node.set_unless['wsrep']['password']               = secure_password
  node.save
end

if platform_family?('windows') or platform_family?('mac_os_x')
  fail_msg = "Windows and Mac OSX is not supported by the Galera MySQL solution."
  Chef::Application.fatal!(fail_msg)
end

if node['galera']['nodes'].empty?
  fail_msg = "You must set node['galera']['nodes'] to a list of IP addresses or hostnames for each node in your cluster"
  Chef::Application.fatal(fail_msg)
end

# Any MySQL server packages installed need to be removed, as
# Galera is a specially-packaged MySQL server version that includes
# the Galera WSREP plugin code compiled into the server.
node['mysql']['server']['packages'].each do |package_name|
  package package_name do
    action :remove
  end
end

# Download, cache, then install the Galera WSREP package
arch = node['kernel']['machine']
download_root = node['galera']['packages']['galera']['download_root']
galera_package = node['galera']['packages']['galera'][arch]
Chef::Log.info "Downloading #{galera_package}"
remote_file "#{Chef::Config[:file_cache_path]}/#{galera_package}" do
  source "#{download_root}/#{galera_package}"
  action :create_if_missing
end

package "galera" do
  source "#{Chef::Config[:file_cache_path]}/#{galera_package}"
end

# Download, cache, and then install the custom MySQL server for Galera package
download_root = node['galera']['packages']['mysql_server']['download_root']
mysql_server_package = node['galera']['packages']['mysql_server'][arch]
Chef::Log.info "Downloading #{mysql_server_package}"
remote_file "#{Chef::Config[:file_cache_path]}/#{mysql_server_package}" do
  source "#{download_root}/#{mysql_server_package}"
  action :create_if_missing
end

package "mysql_server_galera" do
  source "#{Chef::Config[:file_cache_path]}/#{mysql_server_package}"
end

[File.dirname(node['mysql']['pid_file']),
  File.dirname(node['mysql']['tunable']['slow_query_log']),
  node['mysql']['confd_dir'],
  node['mysql']['log_dir'],
  node['mysql']['data_dir']].each do |directory_path|
  directory directory_path do
    owner "mysql"
    group "mysql"
    action :create
    recursive true
  end
end

# The following variables in the my.cnf MUST BE set
# this way for Galera to work properly.
node.set['mysql']['tunable']['binlog_format'] = "ROW"
node.set['mysql']['tunable']['innodb_autoinc_lock_mode'] = "2"
node.set['mysql']['tunable']['innodb_locks_unsafe_for_binlog'] = "1"
node.set['mysql']['tunable']['innodb_support_xa'] = "0"

skip_federated = case node['platform']
                 when 'fedora', 'ubuntu', 'amazon'
                   true
                 when 'centos', 'redhat', 'scientific'
                   node['platform_version'].to_f < 6.0
                 else
                   false
                 end

# The wsrep_urls is a collection of the cluster node URIs with gcomm:// at the end
# to indicate to the first node that runs it to initialize a cluster.
cluster_urls = ""
node['galera']['nodes'].each do |address|
  cluster_urls = "#{cluster_urls}gcomm://#{address}:#{port},"
end
cluster_urls = "#{cluster_urls}gcomm://"

template "#{node['mysql']['conf_dir']}/my.cnf" do
  source "my.cnf.erb"
  owner "root"
  group node['mysql']['root_group']
  mode 00644
  case node['mysql']['reload_action']
  when 'restart'
    notifies :restart, "service[mysql]", :immediately
  when 'reload'
    notifies :reload, "service[mysql]", :immediately
  else
    Chef::Log.info "my.cnf updated but mysql.reload_action is #{node['mysql']['reload_action']}. No action taken."
  end
  variables (
    "skip_federated" => skip_federated,
    "wsrep_urls" => cluster_urls
  )
end

sst_receive_address = node['network']["ipaddress_#{node['wsrep']['sst_receive_interface']}"]
template "#{node['mysql']['confd_dir']}/wsrep.cnf" do
  source "wsrep.cnf.erb"
  owner "root"
  group node['mysql']['root_group']
  mode 00644
  case node['mysql']['reload_action']
  when 'restart'
    notifies :restart, "service[mysql]", :immediately
  when 'reload'
    notifies :reload, "service[mysql]", :immediately
  else
    Chef::Log.info "wsrep.cnf updated but mysql.reload_action is #{node['mysql']['reload_action']}. No action taken."
  end
  variables (
    "sst_receive_address" => sst_receive_address
  )
end

execute 'mysql-install-db' do
  command "mysql_install_db"
  action :run
  not_if { File.exists?(node['mysql']['data_dir'] + '/mysql/user.frm') }
end

service "mysql" do
  service_name node['mysql']['service_name']
  if node['mysql']['use_upstart']
    provider Chef::Provider::Service::Upstart
  end
  supports :status => true, :restart => true, :reload => true
  action :enable, :start
end

# set the root password for situations that don't support pre-seeding.
# (eg. platforms other than debian/ubuntu & drop-in mysql replacements)
execute "assign-root-password" do
  command "\"#{node['mysql']['mysqladmin_bin']}\" -u root password \"#{node['mysql']['server_root_password']}\""
  action :run
  only_if "\"#{node['mysql']['mysql_bin']}\" -u root -e 'show databases;'"
end

execute "delete-blank-users" do
  sql_command = "SET wsrep_on=OFF; DELETE FROM mysql.user WHERE user='';"
  command %Q["#{node['mysql']['mysql_bin']}" -u root #{node['mysql']['server_root_password'].empty? ? '' : '-p' }"#{node['mysql']['server_root_password']}" -e "#{sql_command}"]
  action :run
end

wsrep_user = node['wsrep']['user']
wsrep_pass = node['wsrep']['password']
execute "grant-wsrep-user" do
  sql_command = "SET wsrep_on=OFF; GRANT ALL ON *.* TO #{wsrep_user}@'%' IDENTIFIED BY '#{wsrep_pass}';"
  command %Q["#{node['mysql']['mysql_bin']}" -u root #{node['mysql']['server_root_password'].empty? ? '' : '-p' }"#{node['mysql']['server_root_password']}" -e "#{sql_command}"]
  action :run
end
