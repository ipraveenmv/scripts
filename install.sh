#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

# defaults 
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""

for i in "$@"
do
    case $i in
        --hostname=*)
        HOSTNAME="${i#*=}" 
        ;;
        --username=*)
        USERNAME="${i#*=}"
        ;;
        --password=*)
        PASSWORD="${i#*=}"
        ;;
        --email=*)
        EMAIL="${i#*=}"
        ;;
        --storageaccount=*)
        STORAGEACCOUNT="${i#*=}"
        ;;    
        --container=*)
        CONTAINER="${i#*=}"
        ;;            
        *)
        ;;
    esac
done

# Install Dependencies
apt-get update
apt-get upgrade -y
apt-get install -y php8.3 php8.3-cli php8.3-common php8.3-imap php8.3-redis php8.3-snmp php8.3-xml php8.3-zip php8.3-mbstring php8.3-curl php8.3-gd php8.3-mysql apache2 mariadb-server certbot nfs-common python3-certbot-apache unzip

# Create the database and user
DBPASSWORD=$(openssl rand -base64 14)
mysql -e "CREATE DATABASE nextcloud;GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';FLUSH PRIVILEGES;"

# Mount the file storage
mkdir -p /mnt/files
echo "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER  /mnt/files    nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail    0 0" >> /etc/fstab 
mount /mnt/files

# Download Nextcloud
cd /var/www/html
wget https://download.nextcloud.com/server/releases/nextcloud-31.0.3.zip
unzip nextcloud-31.0.3.zip
chown -R root:root nextcloud
cd nextcloud

# Install Nextcloud
php occ maintenance:install --database "mysql" --database-name "nextcloud"  --database-user "nextcloud" --database-pass "$DBPASSWORD" --admin-user "$USERNAME" --admin-pass "$PASSWORD" --data-dir /mnt/files
sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s/  'overwrite.cli.url' => 'https:\/\/localhost',/  'overwrite.cli.url' => 'http:\/\/$HOSTNAME',/g" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/files

# Configure Apache
tee -a /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
    ServerName $HOSTNAME
    Redirect permanent / https://$HOSTNAME/
</VirtualHost>

<VirtualHost *:443>
    ServerName $HOSTNAME
    DocumentRoot /var/www/html/nextcloud

    <Directory /var/www/html/nextcloud/>
        Require all granted
        Options FollowSymlinks MultiViews
        AllowOverride All
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog /var/log/apache2/$HOSTNAME.error_log
    CustomLog /var/log/apache2/$HOSTNAME.access_log common

    Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite
a2enmod headers

# Obtain a Certificate from Let's Encrypt
certbot run -d $HOSTNAME --agree-tos --apache -m $EMAIL -n
systemctl restart apache2
