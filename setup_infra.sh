#!/bin/bash

set -e

# Using the "-u" flag will set the infraportal files to be owned by $USER
use_apache_user=true
while getopts "u" opt; do
    case $opt in
        u )
            use_apache_user=false
            ;;
        \? )
            echo "Invalid option: -$OPTARG" >&2
            ;;
    esac
done


# In order to setup aliases for composer and drush, this should be run as the user of the server administrator
# Although they are stored in the Drupal container, the "composer" and "drush" commands will work on the host

if [ $USER != "root" ]; then
    echo "Script must be run as root";
    exit 1;
fi;

# Contains the DB secrets - this should end up being provided by GitHub secrets for privacy and security concerns.
source db_info.env


# This installation assumes a basic CentOS/SL7 image and so installs the necessary packages. There is scope to move this setup to Aquilon
echo "Starting to setup InfraPortal";
echo "Updating machine and installing git";
sudo yum update -y && sudo yum install git docker-ce docker-compose -y;
if [ ! -d "infrastructure-portal" ]; then
    git clone https://github.com/stfc/infrastructure-portal.git;
fi;
cd infrastructure-portal;
echo "Switching to branch $infra_branch";
git checkout $infra_branch;

# Setting database details in settings.php
settings_path='sites/default/settings.php';
cp 'sites/default/default.settings.php' $settings_path;
# variables sourced from db_info.env
db_settings=$(cat <<- END
\$config["system.logging"]["error_level"] = "all"; // hide|some|all|verbose
\$settings["hash_salt"] = "KAJENFL-wewefAKJERNFLKEJ-LEKbdfbRJALKGBREKJGB-AELRGKJB";
\$settings["config_sync_directory"] = "../config";
\$databases["default"]["default"] = array (
    "database" => "$db_name",
    "username" => "$db_user",
    "password" => "$db_passwd",
    "prefix" => "",
    "host" => "$db_container",
    "port" => "$db_port",
    "namespace" => "Drupal\\Core\\Database\\Driver\\mysql",
    "driver" => "mysql",
);
END
)
echo "$db_settings" >> $settings_path;

# The DB dump is moved to a folder that the mysql container will use as part of its startup
echo "Saving website database dump to /opt/drupal/";
if [ ! -d "/opt/drupal" ]; then
	echo "Making /opt/drupal";
	mkdir /opt/drupal;
fi;

if [ ! -f "/opt/drupal/infraportal.sql" ]; then
    echo "Copying .sql file to /opt/drupal/";
    if [ -f ../infraportal.sql ]; then
        cp ../infraportal.sql /opt/drupal/infraportal.sql;
    else
        echo "Make sure there is a database dump in the same dir as this script named 'infraportal.sql'";
    fi;
else
    read -p "There is already a sql file in /opt/drupal. If this is correct, press enter to continue. Otherwise ctrl-C to exit this script";
fi;

# Can remove this line once docker-compose is updated in main repo
cp ../docker-compose.yaml docker-compose.yaml;

# TODO: Test this works correctly
if ( $use_apache_user ); then
    source ./set_permissions.sh
else
    source ./set_permissions.sh -u $SUDO_USER
fi

echo "Running as $SUDO_USER. Setting group permissions and aliases now";
usermod -aG docker $SUDO_USER;  # Adds user to group
# exec su -l $SUDO_USER;          # Refreshes groups to avoid having to logout and login
echo "Logout and back in to refresh group memberships"

# Allows drush to be run from the infrastructure-portal dir
echo "alias drush='docker-compose exec drupal /opt/drupal/web/vendor/bin/drush'" >> /home/$SUDO_USER/.bash_aliases;

# Start the containers
systemctl start docker;

echo "Installation complete. Run `docker-compose up` from the infrastructure-portal directory now!"
echo "First time starting up may take longer as the database is imported for the first time"
# Uncomment if infraportal should be automatically started
# docker-compose up &

