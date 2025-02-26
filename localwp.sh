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

  # Start proxy
  cd ~/Local-Sites/proxy
  docker compose up -d
  
  # Generate SSL cert for mail.local
  generate_ssl_cert "mail.local"
  
  # Add mail.local to hosts file
  if ! grep -q "mail.local" /etc/hosts; then
    sudo bash -c "echo '127.0.0.1 mail.local' >> /etc/hosts"
  fi
  
  # Start mailhog
  cd ~/Local-Sites/mailhog
  docker compose up -d
  
  echo "✅ Proxy system and MailHog set up successfully!"
  echo "📧 Mail catcher UI available at: https://mail.local"
  echo "📧 SMTP server available at: localhost:1025"
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
  cd $SITE_DIR
  
  # Generate random passwords
  DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  DB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # Generate SSL certificate for the domain
  generate_ssl_cert $SITE_DOMAIN
  generate_ssl_cert pma.$SITE_DOMAIN
  
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
  echo "Once WordPress setup is complete, you can log in at:"
  echo "🔑 Admin URL: https://${SITE_DOMAIN}/wp-admin/"
  echo ""
  echo "⚠️ Since this uses self-signed certificates, you'll need to accept the security warning in your browser."
  echo "📧 All emails sent from WordPress will be captured by MailHog and available at https://mail.local"
}

# ----- List All Sites -----
list_sites() {
  echo "WordPress Sites:"
  echo "================"
  
  local site_count=0
  
  for site in ~/Local-Sites/*/docker-compose.yml; do
    if [ "$site" != "~/Local-Sites/*/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      site_domain="${site_name}.local"
      
      # Check if running
      if docker ps --format '{{.Names}}' | grep -q "${site_name}-wordpress"; then
        status="✅ Running"
      else
        status="❌ Stopped"
      fi
      
      echo "- ${site_name} (${site_domain}) - ${status}"
      site_count=$((site_count + 1))
    fi
  done
  
  if [ $site_count -eq 0 ]; then
    echo "No WordPress sites found."
  fi
  
  # Check mail system status
  if docker ps --format '{{.Names}}' | grep -q "local-wp-mailhog"; then
    echo ""
    echo "Mail System: ✅ Running (https://mail.local)"
  else
    echo ""
    echo "Mail System: ❌ Stopped"
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
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ]; then
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
  
  # Delete all sites
  for site in ~/Local-Sites/*/docker-compose.yml; do
    if [ "$site" != "~/Local-Sites/*/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/Local-Sites/mailhog/docker-compose.yml" ]; then
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
      
      echo "✅ Site deleted: $site_name"
    fi
  done
  
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
  echo "8. Start mail system"
  echo "9. Stop mail system"
  echo "10. Exit"
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
    10) exit 0 ;;
    *) echo "Invalid choice. Please try again." ;;
  esac
  
  echo ""
  read -p "Press Enter to return to menu..."
  main_menu
}

# Start the menu
main_menu