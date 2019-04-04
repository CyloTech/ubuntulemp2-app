#!/bin/bash
echo "**************************************************************"
echo "*              Installing NGINX & PHP-FPM 7                  *"
echo "**************************************************************"

echo "Creating directories"
mkdir -p /home/appbox/config/nginx/sites-enabled
mkdir -p /home/appbox/config/nginx/modules-enabled
mkdir -p /home/appbox/config/php-fpm/pool.d
mkdir -p /home/appbox/logs/nginx
mkdir -p /home/appbox/public_html

# Move Sources
echo "Moving sources"
mv /sources/nginx.conf /home/appbox/config/nginx/nginx.conf
mv /sources/default-site.conf /home/appbox/config/nginx/sites-enabled/default-site.conf
mv /sources/php-fpm.conf /home/appbox/config/php-fpm/php-fpm.conf
mv /sources/www.conf /home/appbox/config/php-fpm/pool.d/www.conf

# Copy NGINX fastcgi_params
echo "Setting up NGINX"
cp /etc/nginx/fastcgi_params /home/appbox/config/nginx/fastcgi_params

# Setup NGINX Daemon
echo "Setting up NGINX daemon"
mkdir -p /etc/service/nginx
cat << EOF >> /etc/service/nginx/run
#!/bin/sh
exec /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;"
EOF
chmod +x /etc/service/nginx/run

# Setup PHP-FPM Daemon
echo "Setting up PHP-FPM daemon"
mkdir -p /etc/service/phpfpm
cat << EOF >> /etc/service/phpfpm/run
#!/bin/sh
exec /usr/sbin/php-fpm7.2 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf
EOF
chmod +x /etc/service/phpfpm/run

echo "Finished installing NGINX & PHP-FPM"