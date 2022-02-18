#!/bin/bash

set -e

# NOTES
# PRODUCTION
# Use the "u" option to set the current user as owner of the files
# The script should be run with infraportal_setup as the working directory
# infraportal.sql should be present in infraportal_setup and be the most recent database export
# Update and copy/rename DEMO_db_info.env to contain the correct information
# Insertion of database info into docker-composer.yaml relies on placeholder tags of the form {{placeholder}}
#	TODO: Upload docker-compose.yaml with the placeholders to the main repo - the docker-compose file in infraportal_setup can then be removed.


####
# INITIAL SETUP
####

file_owner="33" # Apache UID
while getopts "u" opt; do
    case $opt in
        u )
            file_owner=$SUDO_USER;;
        \? )
            echo "Invalid option: -$OPTARG" >&2;;
    esac
done

if [ $USER != "root" ]; then
    echo "Script must be run as root";
    exit 1;
fi;

if [ ! -d "/opt/drupal" ]; then
	echo "Making /opt/drupal";
	mkdir /opt/drupal;
  chmod 770 /opt/drupal;
fi;

if [ ! -f "./db_info.env" ]; then
	echo "Please create db_info.env and fill in the database info (copy from DEMO_db_info.env)";
	exit 1
fi;
if [ ! -f "./set_permissions.sh" ]; then
	echo "Could not find set_permissions.sh in working directory. Please run $0 from infraportal_setup/";
	exit 1
fi;

# Contains the DB secrets - this should end up being provided by GitHub secrets for privacy and security concerns.
source db_info.env

infraportal_path="/opt/drupal/infrastructure-portal"

# This installation assumes a basic CentOS/SL7 image and so installs the necessary packages. There is scope to move this setup to Aquilon
# TODO: Add this to the Aquilon profile
packages=(
  "git"
  "docker-ce"
  "docker-compose"
  "haproxy"
);
echo "Starting to setup InfraPortal";
echo "Updating machine and installing: ${packages[@]}";
sudo yum update -y && sudo yum install ${packages[@]} -y;
if [ ! -d "${infraportal_path}" ]; then
    echo "Cloning infraportal to $infraportal_path"
    echo "Checking out $INFRA_BRANCH"
    git clone --branch $INFRA_BRANCH https://github.com/stfc/infrastructure-portal.git $infraportal_path
fi;

####
# HAPROXY
####

if [ ! -f "configs/haproxy.cfg" ]; then
  echo "haproxy.cfg not found"
  read -p "Press enter to continue without haproxy setup. Otherwise ctrl-c to exit the script now";
else
  sudo install -o root -g root -m 0644 configs/haproxy.cfg /etc/haproxy/haproxy.cfg
  sudo install -o root -g root -m 0644 configs/ryslog-haproxy.conf /etc/rsyslog.d/haproxy.conf
  sudo systemctl reload rsyslog
fi;

####
# DATABASE CREDENTIALS
# variables sourced from db_info.env
####

# settings.php

settings_path="${infraportal_path}/sites/default/settings.php";
cp "${infraportal_path}/sites/default/default.settings.php" $settings_path;
db_settings=$(cat <<- END
\$settings['reverse_proxy'] = TRUE;
\$settings['reverse_proxy_addresses'] = ['172.17.0.1','172.19.0.1','127.0.0.1'];
\$settings['trusted_host_patterns'] = [
  '^www\.infraportal\.org\.uk$',
  '^infraportal\.org\.uk$'
];
\$config["system.logging"]["error_level"] = "hide"; // hide|some|all|verbose
\$settings["hash_salt"] = "$HASH_SALT";
\$settings["config_sync_directory"] = "sites/default/config";
\$databases["default"]["default"] = array (
    "database" => "$DB_NAME",
    "username" => "$DB_USER",
    "password" => "$DB_PASSWD",
    "prefix" => "",
    "host" => "$DB_CONTAINER",
    "port" => "$DB_PORT",
    "namespace" => "Drupal\\Core\\Database\\Driver\\mysql",
    "driver" => "mysql",
);
END
)
echo "$db_settings" >> $settings_path;

# docker-compose.yaml

docker_compose_path="${infraportal_path}/docker-compose.yaml";
cp prod-docker-compose.yaml $docker_compose_path;  # Can remove this line once docker-compose is updated in main repo to have placeholder db info
echo "Copied prod-docker-compose.yaml to $docker_compose_path"

####
# FILE PERMISSIONS
####

echo "Setting owner to $file_owner"
source ./set_permissions.sh $infraportal_path $file_owner

echo "Running as $SUDO_USER. Setting group permissions and aliases now";
usermod -aG docker $SUDO_USER;  # Adds user to group
# exec su -l $SUDO_USER;          # Refreshes groups to avoid having to logout and login
echo "Logout and back in to refresh group memberships"

# Allows drush to be run from the host machine
drush_function=$(cat <<- END
function drush() {
        cur_dir=\$(pwd)
        cd /opt/drupal/infrastructure-portal
        docker-compose exec drupal /opt/drupal/web/vendor/bin/drush "\$@"
        cd \$cur_dir
};
END
)
echo "$drush_function" >> /home/$SUDO_USER/.bashrc;
# Start the containers
systemctl enable docker --now;
systemctl enable haproxy --now;

echo "Installation complete. Run `docker-compose up` from the infrastructure-portal directory now!"
echo "First time starting up may take longer as the database is imported for the first time"
# docker-compose up &
