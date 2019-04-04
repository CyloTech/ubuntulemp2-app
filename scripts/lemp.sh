#!/bin/bash
set -e

if [ ! -f /etc/lemp2_configured ]; then

echo "**************************************************************"
echo "*                                                            *"
echo "*              This is a fresh installation                  *"
echo "*                                                            *"
echo "**************************************************************"

    # Create Directories
    echo "Creating config directory"
    mkdir -p /home/appbox/config

    # Install NGINX & PHP-FPM 7
    echo "Installing NGINX & PHP-FPM 7"
    /bin/sh /scripts/nginx_php7.sh

    if [ "${INSTALL_MYSQL}" = true ]; then
        # Install MySQL
        echo "Installing MySQL"
        /bin/sh /scripts/mysql.sh
    fi

    # Set Permissions
    echo "Setting Permissions on homedir"
    chown -R appbox:appbox /home/appbox

    # Clean Up
    echo "Cleaning up"
    rm -fr /sources

    echo "Finishing Install"
    # Finish Install
    if [ "${APEX_CALLBACK}" = true ]; then
        until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
            do
            sleep 5
        done
    fi
    touch /etc/lemp2_configured

fi