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

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install Dependencies
apt-get update && apt-get upgrade -y

# Add universe repository if not already present
if ! grep -q "^deb .*universe" /etc/apt/sources.list; then
    add-apt-repository universe
    apt-get update
fi

# Install required packages
REQUIRED_PACKAGES=(
    php8.1
    php8.1-cli
    php8.1-common
    php8.1-imap
    php8.1-redis
    php8.1-snmp
    php8.1-xml
    php8.1-zip
    php8.1-mbstring
    php8.1-curl
    php8.1-gd
    php8.1-mysql
    apache2
    mariadb-server
    certbot
    nfs-common
    python3-certbot-apache
    unzip
)

for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! command_exists "$package"; then
        echo "Installing $package..."
        apt-get install -y "$package" || { echo "Failed to install $package. Exiting."; exit 1; }
    else
        echo "$package is already installed."
    fi
done

# Create the database and user
DBPASSWORD=$(openssl rand -base64 14)
mysql -e "CREATE DATABASE nextcloud; GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD'; FLUSH PRIVILEGES;"

# Mount the file storage
mkdir -p /mnt/files
echo "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER  /mnt/files    nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail    0 0" >> /etc/fstab 
mount /mnt/files

# Download Nextcloud
cd /var/www/html || { echo "Failed to change directory to /var/www/html. Exiting."; exit 1; }
wget https://download.nextcloud.com/server/releases/nextcloud-31.0.3.zip
unzip nextcloud-31.0.3.zip || { echo "Failed to unzip Nextcloud. Exiting."; exit 1; }
chown -R root:root nextcloud
cd nextcloud || { echo "Failed to change directory to nextcloud. Exiting."; exit 1; }

# Install Nextcloud
php occ maintenance:install --database "mysql" --database-name "nextcloud" --database-user "nextcloud" --database-pass "$DBPASSWORD" --admin-user "$USERNAME" --admin-pass "$PASSWORD" --data-dir /mnt/files || { echo "Nextcloud installation failed. Exiting."; exit 1; }
sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s/  'overwrite.cli.url' => 'https:\/\/localhost',/  'overwrite.cli.url' => 'http:\/\/$HOSTNAME',/g" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/files

# Configure Apache
tee -a /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
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
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite

#Obtain a Certificate from Let's Encrypt
certbot run -d $HOSTNAME --agree-tos --apache -m $EMAIL -n
systemctl restart apache2
