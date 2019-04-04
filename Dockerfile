FROM phusion/baseimage:master

ENV HOME=/home/appbox \
    DEBIAN_FRONTEND=noninteractive \
    MYSQL_ROOT_PASSWORD=mysqlr00t \
    APEX_CALLBACK=true \
    INSTALL_MYSQL=true

RUN apt update
RUN apt install -y wget \
                   git \
                   nginx \
                   php-fpm \
                   mysql-server \
                   php-mysql \
                   php-curl

RUN mkdir -p /run/php

RUN adduser --system --disabled-password --home ${HOME} --shell /sbin/nologin --group --uid 1000 appbox

ADD /scripts /scripts
RUN chmod -R +x /scripts

RUN mkdir -p /etc/my_init.d
RUN mv /scripts/lemp.sh /etc/my_init.d/20_lemp.sh
RUN chmod -R +x /etc/my_init.d

ADD /sources /sources
EXPOSE 80 3306

# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Use baseimage-docker's init system.
CMD ["/sbin/my_init"]