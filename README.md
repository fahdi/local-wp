# WordPress Local Development Tool

[![Docker](https://img.shields.io/badge/Docker-Required-blue)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

A comprehensive Bash script for creating and managing isolated WordPress development environments using Docker. Similar to Local by Flywheel, this tool allows you to quickly set up multiple WordPress sites with their own local domains, SSL certificates, and advanced configuration options.

## Features

- **One-Command Setup**: Create full WordPress environments with a single command
- **Multi-Site Management**: Create, start, stop, and delete WordPress sites with simple menu options
- **Local Domains**: Automatic `.local` domains with self-signed SSL certificates 
- **Complete Development Stack**: WordPress, MySQL 8.0, phpMyAdmin, and Nginx proxy
- **Mail Testing**: Integrated MailHog to catch and test all outgoing emails
- **Automated Backups**: Daily database backups with retention management
- **Docker-based**: Isolated containers for each site component
- **Direct File Access**: WordPress files accessible directly in your file system
- **Automatic Configuration**: Handles hosts file updates and Docker networking
- **Increased Upload Limits**: 128MB file upload capacity for media and plugins
- **Must-use Plugins**: Auto-configured plugins for mail testing and upload limits

## Prerequisites

### Required Software
- **Docker**: Version 20.10.0 or higher
  - Install from [docker.com](https://www.docker.com/get-started)
  - Ensure Docker daemon is running
- **Docker Compose**: Version 2.0.0 or higher (included with Docker Desktop)
  - Verify with `docker compose version`
- **OpenSSL**: For generating self-signed certificates
  - Usually pre-installed on macOS/Linux, verify with `openssl version`

### System Requirements
- **Operating System**: 
  - macOS 10.15+
  - Ubuntu 20.04+/Debian 10+/other modern Linux distributions
  - Windows 10/11 with WSL2 (Windows Subsystem for Linux)
- **Disk Space**: At least 1GB free space per WordPress site
- **Memory**: Minimum 4GB RAM recommended
- **Processor**: Any modern multi-core CPU

### Network Requirements
- **Port Availability**: Ports 80 and 443 must be available (not used by other applications)
- **Admin Privileges**: Sudo/administrator access for:
  - Modifying the hosts file (`/etc/hosts`)
  - Binding to privileged ports 80/443

### Additional Requirements
- **Terminal/Command Line**: Access to bash terminal
- **Text Editor**: For viewing and editing WordPress files

## Installation

1. Download the script to your computer
2. Make it executable:
   ```bash
   chmod +x localwp.sh
   ```
3. Run the script:
   ```bash
   ./localwp.sh
   ```
4. Select option 1 for "First-time setup" to initialize the system

## Usage

### Creating a New WordPress Site

1. Run the script and select option 2 (Create new WordPress site)
2. Enter a site name when prompted (e.g., "mysite")
3. The script will set up everything and provide access URLs
4. Access your site at `https://mysite.local` (accept the self-signed certificate warning)
5. Complete the WordPress setup wizard in your browser

### Managing Sites

The script provides a menu-based interface with these options:

1. **First-time setup**: Initialize the system (run once)
2. **Create new WordPress site**: Set up a new WordPress instance
3. **List all sites**: View all sites with their running status
4. **Start a site**: Start a stopped WordPress site
5. **Stop a site**: Stop a running WordPress site
6. **Delete a site**: Remove a WordPress site and all its data
7. **Delete ALL sites**: Remove all WordPress sites (with confirmation)

### System Services

8. **Start mail system**: Start the MailHog email testing system
9. **Stop mail system**: Stop the MailHog email testing system
10. **Start backup system**: Enable automated daily backups
11. **Stop backup system**: Disable automated daily backups

### Maintenance

12. **Fix upload limits**: Increase upload limits for existing sites

### Backup Operations

13. **Backup a site manually**: Create an on-demand database backup
14. **Backup ALL sites now**: Back up all sites immediately
15. **Restore from backup**: Restore a site from a previous backup
16. **List all backups**: View all available backups

### Directory Structure

The script creates the following directory structure:

```
~/Local-Sites/
├── [sitename]/
│   ├── wordpress/        # WordPress files (directly editable)
│   │   ├── wp-content/   # Themes, plugins, and uploads
│   │   └── uploads-config/  # PHP configuration for uploads
│   ├── database/         # MySQL database files
│   ├── logs/             # Log files (if any)
│   ├── docker-compose.yml
│   ├── .env              # Environment variables
│   └── README.md         # Site-specific information and credentials
├── proxy/                # Nginx proxy with SSL support
├── mailhog/              # Mail testing system
└── backups/              # Database backups with daily scheduling
```

### Access Points for Each Site

- **WordPress Site**: `https://[sitename].local`
- **Database Admin**: `https://pma.[sitename].local`
- **Mail Catcher**: `https://mail.local` (shared across all sites)

## Working with WordPress Sites

### Accessing WordPress Files

Edit WordPress files directly at:
```
~/Local-Sites/[sitename]/wordpress/
```

Changes are immediately reflected on your site.

### Plugin & Theme Development

Navigate to the WordPress content directory:
```
cd ~/Local-Sites/[sitename]/wordpress/wp-content/
```
Create or modify plugins and themes directly in this location.

### Database Management

Access phpMyAdmin at `https://pma.[sitename].local` using credentials stored in your site's README.md file.

### Testing Emails

1. Configure your WordPress site to send an email (contact form, password reset, etc.)
2. All emails are captured by MailHog and viewable at `https://mail.local`
3. No emails are actually sent externally

### Managing Backups

- **View backups**: Select option 16 from the menu
- **Create manual backup**: Select option 13 from the menu
- **Restore from backup**: Select option 15 from the menu

Backups are stored in `~/Local-Sites/backups/[sitename]/` and are automatically pruned after 7 days.

## Increased Upload Limits

The system is configured with increased upload limits:
- Maximum upload size: 128MB
- Post max size: 128MB
- Memory limit: 256MB
- Max execution time: 300 seconds

This allows for uploading large themes, plugins, and media files.

## Troubleshooting

### SSL Certificate Warnings

The system uses self-signed certificates. You can safely proceed by accepting the security risk in your browser for local development.

### Site Not Accessible

Check that:
1. Your site's containers are running (option 3 in the menu)
2. The proxy container is running (should show as running in option 3)
3. Your hosts file has been properly updated (check `/etc/hosts`)

### Email Testing Not Working

Make sure the mail system is running (option 8 in the menu)

### Upload Limits Not Working

If you're having issues with upload limits on an existing site, use option 12 from the menu to fix the configuration.

## Notes

- This tool is for local development only
- SSL certificates are self-signed and will trigger browser warnings
- Each WordPress site requires approximately 500MB of disk space
- The script requires ports 80 and 443 to be available
- Automated backups retain files for 7 days by default