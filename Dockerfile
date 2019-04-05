FROM repo.cylo.io/baseimage

ENV MYSQL_ROOT_PASSWORD=mysqlr00t \
    APEX_CALLBACK=true \
    INSTALL_MYSQL=true \
    INSTALL_NGINXPHP=true