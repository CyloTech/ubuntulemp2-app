FROM repo.cylo.io/baseimage

ENV MYSQL_ROOT_PASSWORD=mysqlr00t \
    APEX_CALLBACK=true \
    INSTALL_MYSQL=true \
    INSTALL_NGINXPHP=true

RUN apt update
RUN apt install -y php-curl --fix-broken

# Clean up APT when done.
RUN apt autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*