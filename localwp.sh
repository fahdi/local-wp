#!/bin/bash

# WordPress Multi-Site Setup System
# Similar to Local by Flywheel, this allows multiple WordPress sites
# to run concurrently, each with its own .local domain

# ----- Initial Setup (Run once) -----
setup_system() {
  echo "Setting up WordPress multi-site system..."
  
  # Create main directory
  mkdir -p ~/Local-Sites/proxy
  mkdir -p ~/Local-Sites/mailhog
  mkdir -p ~/Local-Sites/backups
  cd ~/Local-Sites
  
  # Create Docker network for all sites
  docker network create local-wp-network 2>/dev/null || true
  
  # Create docker-compose for proxy with SSL support for .local domains
  cat > ~/Local-Sites/proxy/docker-compose.yml << 'EOF'
services:
  nginx-proxy:
    image: jwilder/nginx-proxy:alpine
    container_name: local-wp-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - ./certs:/etc/nginx/certs
      - ./vhost.d:/etc/nginx/vhost.d
      - ./html:/usr/share/nginx/html
      - ./conf.d:/etc/nginx/conf.d
    restart: unless-stopped
    networks:
      - proxy-network

networks:
  proxy-network:
    external: true
    name: local-wp-network
EOF

  # Set up MailHog mail catcher
  cat > ~/Local-Sites/mailhog/docker-compose.yml << 'EOF'
services:
  mailhog:
    image: mailhog/mailhog
    container_name: local-wp-mailhog
    ports:
      - "1025:1025"  # SMTP port
    environment:
      - VIRTUAL_HOST=mail.local
      - VIRTUAL_PORT=8025
      - VIRTUAL_PROTO=http
      - HTTPS_METHOD=redirect
    networks:
      - mailhog-network

networks:
  mailhog-network:
    external: true
    name: local-wp-network
EOF

  # Set up backup system scheduler
  cat > ~/Local-Sites/backups/docker-compose.yml << 'EOF'
version: '3'

services:
  backup-scheduler:
    image: mcuadros/ofelia:latest
    container_name: wp-backup-scheduler
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config.ini:/etc/ofelia/config.ini
      - ../:/sites:ro
      - ./:/backups
    restart: unless-stopped
    networks:
      - backup-network

networks:
  backup-network:
    external: true
    name: local-wp-network
EOF

  # Create scheduler configuration file
  cat > ~/Local-Sites/backups/config.ini << 'EOF'
[global]
# Backup schedule configuration

[job-exec "backup-all-sites"]
schedule = @daily
container = wp-backup-scheduler
command = /bin/sh -c "cd /backups && ./backup-all-sites.sh"
EOF

  # Create backup script for all sites
  cat > ~/Local-Sites/backups/backup-all-sites.sh << 'EOF'
#!/bin/bash

BACKUP_ROOT="/backups"
DATE=$(date +"%Y-%m-%d")
echo "Starting backup of all WordPress sites at $(date)"

# Find all WordPress sites
for site_dir in /sites/*/; do
  if [ -f "${site_dir}docker-compose.yml" ]; then
    site_name=$(basename "${site_dir}")
    
    # Skip proxy and mailhog directories
    if [[ "$site_name" != "proxy" && "$site_name" != "mailhog" && "$site_name" != "backups" ]]; then
      echo "Backing up site: $site_name"
      
      # Create backup directory for site
      mkdir -p "${BACKUP_ROOT}/${site_name}"
      
      # Get database password from .env file if it exists
      if [ -f "${site_dir}.env" ]; then
        DB_PASSWORD=$(grep DB_PASSWORD "${site_dir}.env" | cut -d '=' -f2)
      else
        DB_PASSWORD="wordpress"  # Default password if .env not found
      fi
      
      # Create backup of database - only if container is running
      if docker ps --format '{{.Names}}' | grep -q "${site_name}-db"; then
        echo "  - Backing up database..."
        docker exec "${site_name}-db" mysqldump -u wordpress -p${DB_PASSWORD} wordpress > "${BACKUP_ROOT}/${site_name}/${DATE}-${site_name}-db.sql"
        echo "  ✅ Backup completed for $site_name"
      else
        echo "  ⚠️ Database container not running for $site_name, skipping backup"
      fi
    fi
  fi
done

echo "Backup process completed at $(date)"

# Cleanup old backups (keep last 7 days)
echo "Cleaning up old backups..."
find "${BACKUP_ROOT}" -type f -name "*.sql" -mtime +7 -delete

echo "All operations completed successfully"
EOF

  # Make the script executable
  chmod +x ~/Local-Sites/backups/backup-all-sites.sh

  # Create directories
  mkdir -p ~/Local-Sites/proxy/{certs,vhost.d,html,conf.d}
  
  # Create default SSL configuration
  cat > ~/Local-Sites/proxy/conf.d/default.conf << 'EOF'
# Default SSL configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
ssl_prefer_server_ciphers on;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
EOF

  # Create uploads configuration to increase file size limits
  cat > ~/Local-Sites/proxy/conf.d/uploads.conf << 'EOF'
# Increase upload size limits
client_max_body_size 128M;
EOF

  # Start proxy
  cd ~/Local-Sites/proxy
  docker compose up -d
  
  # Generate SSL cert for mail.local
  generate_ssl_cert "mail.local"
  
  # Add mail.local to hosts file
  if ! grep -q "mail.local" /etc/hosts; then
    sudo bash -c "echo '127.0.0.1 mail.local' >> /etc/hosts"
  fi
  
  # Start mailhog and backup scheduler
  cd ~/Local-Sites/mailhog
  docker compose up -d
  
  cd ~/Local-Sites/backups
  docker compose up -d
  
  echo "✅ Proxy system, MailHog, and backup system set up successfully!"
  echo "📧 Mail catcher UI available at: https://mail.local"
  echo "📧 SMTP server available at: localhost:1025"
  echo "💾 Automated daily backups enabled"
}

# Generate self-signed SSL certificate for a domain
generate_ssl_cert() {
  local domain=$1
  local cert_dir=~/Local-Sites/proxy/certs
  
  echo "Generating self-signed SSL certificate for ${domain}..."
  
  # Generate SSL certificate
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ${cert_dir}/${domain}.key \
    -out ${cert_dir}/${domain}.crt \
    -subj "/CN=${domain}/O=LocalWP/C=US" \
    -addext "subjectAltName=DNS:${domain},DNS:*.${domain}"
  
  # Create bundle file for Nginx proxy
  cat ${cert_dir}/${domain}.crt ${cert_dir}/${domain}.key > ${cert_dir}/${domain}.pem
  
  echo "✅ SSL certificate generated for ${domain}"
}

# ----- Create New WordPress Site -----
create_site() {
  # Get site name
  read -p "Enter site name (e.g., mysite): " SITE_NAME
  
  if [[ -z "$SITE_NAME" ]]; then
    echo "❌ Site name cannot be empty."
    exit 1
  fi
  
  # Clean site name
  SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  SITE_DOMAIN="${SITE_NAME}.local"
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  
  # Check if site exists
  if [ -d "$SITE_DIR" ]; then
    echo "❌ Site already exists: $SITE_DIR"
    exit 1
  fi
  
  # Create site directory structure for direct file access
  mkdir -p $SITE_DIR/{wordpress,database,logs}
  mkdir -p $SITE_DIR/wordpress/wp-content/mu-plugins
  mkdir -p $SITE_DIR/wordpress/uploads-config  # Directory for upload configuration
  cd $SITE_DIR
  
  # Generate random passwords
  DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  DB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # Generate SSL certificate for the domain
  generate_ssl_cert $SITE_DOMAIN
  generate_ssl_cert pma.$SITE_DOMAIN
  
  # Create custom PHP configuration for file uploads
  cat > $SITE_DIR/wordpress/uploads-config/php.ini << 'EOF'
; Custom PHP settings for WordPress uploads
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
EOF
  
  # Create docker-compose.yml with bind mounts instead of volumes
  cat > docker-compose.yml << EOF
services:
  ${SITE_NAME}-db:
    image: mysql:8.0
    container_name: ${SITE_NAME}-db
    volumes:
      - ./database:/var/lib/mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: ${DB_PASSWORD}
    networks:
      - local-wp-network
    
  ${SITE_NAME}-wordpress:
    image: wordpress:latest
    container_name: ${SITE_NAME}-wordpress
    depends_on:
      - ${SITE_NAME}-db
    volumes:
      - ./wordpress:/var/www/html
      - ./wordpress/uploads-config/php.ini:/usr/local/etc/php/conf.d/uploads.ini
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: ${SITE_NAME}-db
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD}
      WORDPRESS_DB_NAME: wordpress
      VIRTUAL_HOST: ${SITE_DOMAIN}
      VIRTUAL_PORT: 80
      VIRTUAL_PROTO: http
      HTTPS_METHOD: redirect
    networks:
      - local-wp-network

  ${SITE_NAME}-phpmyadmin:
    image: phpmyadmin/phpmyadmin
    container_name: ${SITE_NAME}-phpmyadmin
    depends_on:
      - ${SITE_NAME}-db
    restart: unless-stopped
    environment:
      PMA_HOST: ${SITE_NAME}-db
      PMA_USER: root
      PMA_PASSWORD: ${DB_ROOT_PASSWORD}
      VIRTUAL_HOST: pma.${SITE_DOMAIN}
      VIRTUAL_PORT: 80
      VIRTUAL_PROTO: http
      HTTPS_METHOD: redirect
      UPLOAD_LIMIT: 128M
    networks:
      - local-wp-network

networks:
  local-wp-network:
    external: true
    name: local-wp-network
EOF

  # Create a must-use plugin to configure WordPress to use MailHog for email
  cat > wordpress/wp-content/mu-plugins/mailhog-config.php << 'EOF'
<?php
/**
 * Plugin Name: Local Mail Configuration
 * Description: Configures WordPress to use MailHog for email
 * Version: 1.0
 * Author: Local WP
 */

// Set the SMTP server to the MailHog container
add_action('phpmailer_init', function($phpmailer) {
    $phpmailer->Host = 'local-wp-mailhog';
    $phpmailer->Port = 1025;
    $phpmailer->SMTPAuth = false;
    $phpmailer->isSMTP();
});
EOF

  # Create a must-use plugin to increase WordPress upload limits
  cat > wordpress/wp-content/mu-plugins/upload-limits.php << 'EOF'
<?php
/**
 * Plugin Name: Upload Limits Configuration
 * Description: Increases WordPress upload limits
 * Version: 1.0
 * Author: Local WP
 */

// Increase WordPress upload limits
add_filter('upload_size_limit', function($size) {
    return 134217728; // 128MB in bytes
});

// Remove "Exceeds maximum upload size for this site" error
add_filter('big_image_size_threshold', '__return_false');
EOF

  # Create an .env file with environment variables
  cat > .env << EOF
SITE_NAME=${SITE_NAME}
SITE_DOMAIN=${SITE_DOMAIN}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
EOF

  # Create a README file with site information
  cat > README.md << EOF
# WordPress Site: ${SITE_NAME}

## Site Information
- URL: https://${SITE_DOMAIN}
- Database Admin: https://pma.${SITE_DOMAIN}
- Mail Catcher: https://mail.local

## Directory Structure
- /wordpress: WordPress core files and content
- /database: MySQL database files
- /logs: Log files

## Credentials
### WordPress Database
- Database Name: wordpress
- Username: wordpress
- Password: ${DB_PASSWORD}
- Database Host: ${SITE_NAME}-db

### Database Admin
- Username: root
- Password: ${DB_ROOT_PASSWORD}

## Commands
- Start site: docker compose up -d
- Stop site: docker compose down
- View logs: docker compose logs -f

## Upload Limits
This site is configured with increased upload limits:
- Maximum upload size: 128MB
- Post max size: 128MB 
- Memory limit: 256MB
- Max execution time: 300 seconds

## Backup Information
- Automatic daily backups are enabled
- Backup files are stored in ~/Local-Sites/backups/${SITE_NAME}/
- Backups can be managed through the Local WP tool
EOF

  # Update hosts file
  echo "Updating /etc/hosts file with ${SITE_DOMAIN}..."
  if ! grep -q "${SITE_DOMAIN}" /etc/hosts; then
    sudo bash -c "echo '127.0.0.1 ${SITE_DOMAIN} pma.${SITE_DOMAIN}' >> /etc/hosts"
  fi
  
  # Set correct permissions
  chmod -R 755 wordpress
  
  # Start containers
  docker compose up -d
  
  # Create backup directory
  mkdir -p ~/Local-Sites/backups/${SITE_NAME}
  
  # Wait for WordPress container to be ready (avoid race condition)
  echo "Waiting for WordPress container to be ready..."
  sleep 5
  
  echo "✅ WordPress site created successfully!"
  echo "🌐 Site URL: https://${SITE_DOMAIN}"
  echo "🛠 Database Admin: https://pma.${SITE_DOMAIN}"
  echo "📧 Mail catcher UI: https://mail.local"
  echo "📁 Site directory: ${SITE_DIR}"
  echo ""
  echo "📂 WordPress files are directly accessible at: ${SITE_DIR}/wordpress"
  echo "📂 Database files are stored at: ${SITE_DIR}/database"
  echo ""
  echo "🔄 Upload limits have been increased to 128MB"
  echo "💾 Daily backups will be stored in ~/Local-Sites/backups/${SITE_NAME}/"
  echo ""
  echo "Once WordPress setup is complete, you can log in at:"
  echo "🔑 Admin URL: https://${SITE_DOMAIN}/wp-admin/"
  echo ""
  echo "⚠️ Since this uses self-signed certificates, you'll need to accept the security warning in your browser."
  echo "📧 All emails sent from WordPress will be captured by MailHog and available at https://mail.local"
}

# ----- Fix Upload Limits for Existing Site -----
fix_uploads() {
  read -p "Enter site name to fix uploads for: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    exit 1
  fi
  
  echo "Fixing upload limits for site: $SITE_NAME"
  
  # Create uploads configuration directory if it doesn't exist
  mkdir -p $SITE_DIR/wordpress/uploads-config
  
  # Create PHP configuration file for uploads
  cat > $SITE_DIR/wordpress/uploads-config/php.ini << 'EOF'
; Custom PHP settings for WordPress uploads
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
EOF

  # Create must-use plugin to increase WordPress upload limits
  mkdir -p $SITE_DIR/wordpress/wp-content/mu-plugins
  cat > $SITE_DIR/wordpress/wp-content/mu-plugins/upload-limits.php << 'EOF'
<?php
/**
 * Plugin Name: Upload Limits Configuration
 * Description: Increases WordPress upload limits
 * Version: 1.0
 * Author: Local WP
 */

// Increase WordPress upload limits
add_filter('upload_size_limit', function($size) {
    return 134217728; // 128MB in bytes
});

// Remove "Exceeds maximum upload size for this site" error
add_filter('big_image_size_threshold', '__return_false');
EOF

  # Update docker-compose.yml to include the PHP configuration
  cd $SITE_DIR
  
  # Backup original docker-compose.yml
  cp docker-compose.yml docker-compose.yml.bak
  
  # Update docker-compose.yml using sed
  sed -i.bak '/\.\/wordpress:\/var\/www\/html/a\      - ./wordpress/uploads-config/php.ini:/usr/local/etc/php/conf.d/uploads.ini' docker-compose.yml
  
  # Add UPLOAD_LIMIT for phpMyAdmin if present
  sed -i.bak '/PMA_PASSWORD/a\      UPLOAD_LIMIT: 128M' docker-compose.yml
  
  # Restart containers to apply changes
  docker compose down
  docker compose up -d
  
  echo "✅ Upload limits fixed for site: $SITE_NAME"
  echo "🔄 Maximum upload size increased to 128MB"
  echo "🔄 Changes will take effect after container restart"
}

# ----- Manual Database Backup -----
backup_site() {
  read -p "Enter site name to backup: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    return
  fi
  
  # Create backup directory if it doesn't exist
  BACKUP_DIR=~/Local-Sites/backups/${SITE_NAME}
  mkdir -p $BACKUP_DIR
  
  # Get database password from .env file if it exists
  if [ -f "$SITE_DIR/.env" ]; then
    DB_PASSWORD=$(grep DB_PASSWORD "$SITE_DIR/.env" | cut -d '=' -f2)
  else
    DB_PASSWORD="wordpress"  # Default password if .env not found
  fi
  
  # Create timestamp for backup file
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  BACKUP_FILE="${BACKUP_DIR}/${TIMESTAMP}-${SITE_NAME}-backup.sql"
  
  echo "Backing up database for site: $SITE_NAME"
  
  # Check if site is running
  if ! docker ps | grep -q "${SITE_NAME}-db"; then
    echo "⚠️ Site is not running. Starting containers..."
    cd "$SITE_DIR"
    docker compose up -d
    sleep 5  # Give containers time to start
  fi
  
  # Perform the database backup
  if docker exec "${SITE_NAME}-db" mysqldump -u wordpress -p${DB_PASSWORD} wordpress > "$BACKUP_FILE"; then
    echo "✅ Database backup created successfully!"
    echo "📁 Backup location: $BACKUP_FILE"
    echo "📊 Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
  else
    echo "❌ Backup failed. Please check if the site is running."
  fi
}

# ----- Restore Database Backup -----
restore_backup() {
  read -p "Enter site name to restore backup for: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  BACKUP_DIR=~/Local-Sites/backups/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    return
  fi
  
  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
    echo "❌ No backups found for site: $SITE_NAME"
    return
  fi
  
  # List available backups
  echo "Available backups for $SITE_NAME:"
  ls -1t "$BACKUP_DIR" | grep -E '\.sql$' | nl
  
  # Get backup selection
  read -p "Enter the number of the backup to restore: " BACKUP_NUM
  BACKUP_FILE=$(ls -1t "$BACKUP_DIR" | grep -E '\.sql$' | sed -n "${BACKUP_NUM}p")
  
  if [ -z "$BACKUP_FILE" ]; then
    echo "❌ Invalid selection."
    return
  fi
  
  FULL_BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
  
  # Get database password from .env file if it exists
  if [ -f "$SITE_DIR/.env" ]; then
    DB_PASSWORD=$(grep DB_PASSWORD "$SITE_DIR/.env" | cut -d '=' -f2)
  else
    DB_PASSWORD="wordpress"  # Default password if .env not found
  fi
  
  # Confirm restoration
  echo "You are about to restore the database for $SITE_NAME from backup:"
  echo "  $BACKUP_FILE ($(du -h "$FULL_BACKUP_PATH" | cut -f1))"
  echo "⚠️ Warning: This will overwrite all current data in the database!"
  read -p "Are you sure you want to proceed? (y/n): " CONFIRM
  
  if [[ "$CONFIRM" != "y" ]]; then
    echo "Operation cancelled."
    return
  fi
  
  # Check if site is running
  if ! docker ps | grep -q "${SITE_NAME}-db"; then
    echo "⚠️ Site is not running. Starting containers..."
    cd "$SITE_DIR"
    docker compose up -d
    sleep 5  # Give containers time to start
  fi
  
  # Perform the restoration
  echo "Restoring database from backup..."
  if cat "$FULL_BACKUP_PATH" | docker exec -i "${SITE_NAME}-db" mysql -u wordpress -p${DB_PASSWORD} wordpress; then
    echo "✅ Database restored successfully!"
  else
    echo "❌ Restoration failed. Please check the backup file and try again."
  fi
}

# ----- Run Backup For All Sites -----
backup_all_sites() {
  echo "Running backup for all WordPress sites..."
  
  # Check if backup scheduler is running
  if ! docker ps | grep -q "wp-backup-scheduler"; then
    echo "⚠️ Backup scheduler is not running. Starting it..."
    cd ~/Local-Sites/backups
    docker compose up -d
    sleep 2
  fi
  
  # Execute backup script in container
  if docker exec wp-backup-scheduler /bin/sh -c "cd /backups && ./backup-all-sites.sh"; then
    echo "✅ All sites backed up successfully!"
  else
    echo "❌ Backup process encountered errors. Check the logs for details."
  fi
}

# ----- List All Backups -----
list_backups() {
  BACKUP_DIR=~/Local-Sites/backups
  
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "No backups found. Backup system may not be set up."
    return
  fi
  
  echo "WordPress Site Backups:"
  echo "======================="
  
  # Loop through site directories in backups
  for site_backup in $BACKUP_DIR/*/; do
    if [ "$site_backup" != "$BACKUP_DIR/*/" ]; then
      site_name=$(basename "$site_backup")
      
      # Skip non-site directories
      if [[ "$site_name" != "proxy" && "$site_name" != "mailhog" && ! -f "$site_backup/docker-compose.yml" ]]; then
        echo "Site: $site_name"
        
        # Count backups and get latest backup date
        backup_count=$(find "$site_backup" -name "*.sql" | wc -l)
        
        if [ "$backup_count" -gt 0 ]; then
          latest_backup=$(find "$site_backup" -name "*.sql" | sort -r | head -n 1)
          latest_date=$(basename "$latest_backup" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
          
          echo "  - $backup_count backups found"
          echo "  - Latest backup: $latest_date"
          echo "  - Total backup size: $(du -sh "$site_backup" | cut -f1)"
        else
          echo "  - No backups found"
        fi
        echo ""
      fi
    fi
  done
}

# ----- List All Sites -----
list_sites() {
  echo "WordPress Sites:"
  echo "================"
  
  local site_count=0
  
  for site in ~/Local-Sites/*/docker-compose.yml; do
    if [ "$site" != "~/Local-Sites/*/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      site_domain="${site_name}.local"
      
      # Check if running
      if docker ps --format '{{.Names}}' | grep -q "${site_name}-wordpress"; then
        status="✅ Running"
      else
        status="❌ Stopped"
      fi

      # Check if backups exist
      backup_count=$(find ~/Local-Sites/backups/${site_name} -name "*.sql" 2>/dev/null | wc -l)
      if [ "$backup_count" -gt 0 ]; then
        backup_status="💾 $backup_count backups"
      else
        backup_status="⚠️ No backups"
      fi
      
      echo "- ${site_name} (${site_domain}) - ${status} - ${backup_status}"
      site_count=$((site_count + 1))
    fi
  done
  
  if [ $site_count -eq 0 ]; then
    echo "No WordPress sites found."
  fi
  
  # Check system services status
  echo ""
  echo "System Services:"
  
  # Check proxy status
  if docker ps --format '{{.Names}}' | grep -q "local-wp-proxy"; then
    echo "- Proxy: ✅ Running"
  else
    echo "- Proxy: ❌ Stopped"
  fi
  
  # Check mail system status
  if docker ps --format '{{.Names}}' | grep -q "local-wp-mailhog"; then
    echo "- Mail System: ✅ Running (https://mail.local)"
  else
    echo "- Mail System: ❌ Stopped"
  fi
  
  # Check backup scheduler status
  if docker ps --format '{{.Names}}' | grep -q "wp-backup-scheduler"; then
    echo "- Backup System: ✅ Running (Daily Schedule)"
  else
    echo "- Backup System: ❌ Stopped"
  fi
}

# ----- Start Site -----
start_site() {
  read -p "Enter site name to start: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    exit 1
  fi
  
  cd $SITE_DIR
  docker compose up -d
  
  echo "✅ Site started: ${SITE_NAME}.local"
}

# ----- Stop Site -----
stop_site() {
  read -p "Enter site name to stop: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    exit 1
  fi
  
  cd $SITE_DIR
  docker compose down
  
  echo "✅ Site stopped: $SITE_NAME"
}

# ----- Delete Site -----
# ----- Delete Site -----
delete_site() {
  read -p "Enter site name to delete: " SITE_NAME
  SITE_DIR=~/Local-Sites/${SITE_NAME}
  SITE_DOMAIN="${SITE_NAME}.local"
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    exit 1
  fi
  
  read -p "Are you sure you want to delete $SITE_NAME? This will remove all data! (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then
    echo "Operation cancelled."
    exit 0
  fi
  
  # Ask about backups
  if [ -d "~/Local-Sites/backups/${SITE_NAME}" ]; then
    read -p "Do you want to keep the backups for this site? (y/n): " KEEP_BACKUPS
  fi
  
  # Stop containers
  cd $SITE_DIR
  docker compose down
  
  # Remove site directory
  cd ~/Local-Sites
  rm -rf $SITE_DIR
  
  # Remove SSL certificates
  rm -f ~/Local-Sites/proxy/certs/${SITE_DOMAIN}.*
  rm -f ~/Local-Sites/proxy/certs/pma.${SITE_DOMAIN}.*
  
  # Remove hosts file entry
  sudo sed -i.bak "/^127.0.0.1 ${SITE_DOMAIN}/d" /etc/hosts
  
  # Remove backups if requested
  if [[ "$KEEP_BACKUPS" != "y" ]]; then
    rm -rf ~/Local-Sites/backups/${SITE_NAME}
    echo "🗑️ Site backups deleted"
  else
    echo "💾 Site backups preserved in ~/Local-Sites/backups/${SITE_NAME}"
  fi
  
  echo "✅ Site deleted: $SITE_NAME"
}

# ----- Delete All Sites -----
delete_all_sites() {
  # Count sites
  local site_count=0
  local site_list=""
  
  for site in ~/Local-Sites/*/docker-compose.yml; do
    if [ "$site" != "~/Local-Sites/*/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      site_list="${site_list}  - ${site_name}\n"
      site_count=$((site_count + 1))
    fi
  done
  
  if [ $site_count -eq 0 ]; then
    echo "No WordPress sites found to delete."
    return
  fi
  
  # Confirm deletion of all sites
  echo "The following WordPress sites will be deleted:"
  echo -e "$site_list"
  read -p "Are you sure you want to delete ALL sites? This will remove all data! (yes/no): " CONFIRM
  
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Operation cancelled."
    return
  fi
  
  # Double confirmation with site count
  read -p "Please confirm once more - delete ALL $site_count sites? Type the site count to confirm: " COUNT_CONFIRM
  
  if [[ "$COUNT_CONFIRM" != "$site_count" ]]; then
    echo "Incorrect confirmation. Operation cancelled."
    return
  fi
  
  # Ask about backups
  read -p "Do you want to keep the backups for ALL sites? (y/n): " KEEP_BACKUPS
  
  # Delete all sites
  for site in ~/Local-Sites/*/docker-compose.yml; do
    if [ "$site" != "~/Local-Sites/*/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      site_domain="${site_name}.local"
      
      echo "Deleting site: $site_name..."
      
      # Stop containers
      cd "$site_dir"
      docker compose down
      
      # Remove site directory
      cd ~/Local-Sites
      rm -rf "$site_dir"
      
      # Remove SSL certificates
      rm -f ~/Local-Sites/proxy/certs/${site_domain}.*
      rm -f ~/Local-Sites/proxy/certs/pma.${site_domain}.*
      
      # Remove hosts file entry
      sudo sed -i.bak "/^127.0.0.1 ${site_domain}/d" /etc/hosts
      
      # Remove backups if requested
      if [[ "$KEEP_BACKUPS" != "y" ]]; then
        rm -rf ~/Local-Sites/backups/${site_name}
      fi
      
      echo "✅ Site deleted: $site_name"
    fi
  done
  
  if [[ "$KEEP_BACKUPS" == "y" ]]; then
    echo "💾 All site backups preserved in ~/Local-Sites/backups/"
  else
    echo "🗑️ All site backups have been deleted"
  fi
  
  echo "🗑️ All WordPress sites have been deleted."
}

# ----- Start Mail System -----
start_mail() {
  cd ~/Local-Sites/mailhog
  
  if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Mail system not set up. Please run setup first."
    return
  fi
  
  docker compose up -d
  echo "✅ Mail system started. Web UI: https://mail.local"
}

# ----- Stop Mail System -----
stop_mail() {
  cd ~/Local-Sites/mailhog
  
  if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Mail system not set up. Please run setup first."
    return
  fi
  
  docker compose down
  echo "✅ Mail system stopped."
}

# ----- Start Backup System -----
start_backup() {
  cd ~/Local-Sites/backups
  
  if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Backup system not set up. Please run setup first."
    return
  fi
  
  docker compose up -d
  echo "✅ Backup system started. Daily backups are now enabled."
}

# ----- Stop Backup System -----
stop_backup() {
  cd ~/Local-Sites/backups
  
  if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Backup system not set up. Please run setup first."
    return
  fi
  
  docker compose down
  echo "✅ Backup system stopped. Daily backups are now disabled."
}

# ----- Main Menu -----
main_menu() {
  clear
  echo "===========================================" 
  echo "      WordPress Local Development Tool     "
  echo "===========================================" 
  echo "1. First-time setup (run once)"
  echo "2. Create new WordPress site"
  echo "3. List all sites"
  echo "4. Start a site"
  echo "5. Stop a site"
  echo "6. Delete a site"
  echo "7. Delete ALL sites"
  echo ""
  echo "--- System Services ---"
  echo "8. Start mail system"
  echo "9. Stop mail system"
  echo "10. Start backup system"
  echo "11. Stop backup system"
  echo ""
  echo "--- Maintenance ---"
  echo "12. Fix upload limits for existing site"
  echo ""
  echo "--- Backup Operations ---"
  echo "13. Backup a site manually"
  echo "14. Backup ALL sites now"
  echo "15. Restore from backup"
  echo "16. List all backups"
  echo ""
  echo "17. Exit"
  echo "==========================================="
  read -p "Enter your choice: " CHOICE
  
  case $CHOICE in
    1) setup_system ;;
    2) create_site ;;
    3) list_sites ;;
    4) start_site ;;
    5) stop_site ;;
    6) delete_site ;;
    7) delete_all_sites ;;
    8) start_mail ;;
    9) stop_mail ;;
    10) start_backup ;;
    11) stop_backup ;;
    12) fix_uploads ;;
    13) backup_site ;;
    14) backup_all_sites ;;
    15) restore_backup ;;
    16) list_backups ;;
    17) exit 0 ;;
    *) echo "Invalid choice. Please try again." ;;
  esac
  
  echo ""
  read -p "Press Enter to return to menu..."
  main_menu
}

# Start the menu
main_menu