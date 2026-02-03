#!/usr/bin/env bash
#
# Stock Market Summary - Installation Script
# Sets up the stock summary system with email and scheduling
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -eq 0 ]]; then
  echo_error "Do not run this script as root. Run as a normal user with sudo access."
  exit 1
fi

echo "=============================================="
echo "  Stock Market Summary - Installation"
echo "=============================================="
echo

# Check dependencies
echo_info "Checking dependencies..."

missing_deps=()
for cmd in curl jq bc msmtp; do
  if ! command -v "$cmd" &>/dev/null; then
    missing_deps+=("$cmd")
  fi
done

if [[ ${#missing_deps[@]} -gt 0 ]]; then
  echo_warn "Missing dependencies: ${missing_deps[*]}"
  echo
  read -p "Install missing dependencies? [Y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo_info "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y curl jq bc msmtp msmtp-mta
  else
    echo_error "Cannot continue without dependencies."
    exit 1
  fi
fi

echo_info "All dependencies installed."
echo

# Determine user setup
echo "=============================================="
echo "  User Configuration"
echo "=============================================="
echo
echo "This script can run as:"
echo "  1) Your current user ($(whoami))"
echo "  2) A dedicated 'stocksum' user (recommended for cron jobs)"
echo

read -p "Create dedicated 'stocksum' user? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  run_user="stocksum"
  if id "$run_user" &>/dev/null; then
    echo_info "User '$run_user' already exists."
  else
    echo_info "Creating user '$run_user'..."
    sudo useradd -r -m -s /bin/bash "$run_user"
    echo_info "User '$run_user' created."
  fi
else
  run_user="$(whoami)"
  echo_info "Using current user: $run_user"
fi

user_home=$(eval echo "~$run_user")
echo

# Email configuration
echo "=============================================="
echo "  Email Configuration"
echo "=============================================="
echo

# Check if msmtp is already configured (e.g., from github-backup)
existing_msmtp=""
if [[ -f "$user_home/.msmtprc" ]]; then
  existing_msmtp="$user_home/.msmtprc"
elif [[ -f "/home/ghbackup/.msmtprc" ]]; then
  existing_msmtp="/home/ghbackup/.msmtprc"
fi

if [[ -n "$existing_msmtp" ]]; then
  echo_info "Found existing msmtp config: $existing_msmtp"
  read -p "Use existing email configuration? [Y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if [[ "$existing_msmtp" != "$user_home/.msmtprc" ]]; then
      echo_info "Copying msmtp config to $user_home/.msmtprc"
      sudo cp "$existing_msmtp" "$user_home/.msmtprc"
      sudo chown "$run_user:$run_user" "$user_home/.msmtprc"
      sudo chmod 600 "$user_home/.msmtprc"
    fi
    setup_email="false"
  else
    setup_email="true"
  fi
else
  setup_email="true"
fi

if [[ "$setup_email" == "true" ]]; then
  echo "Setting up Gmail SMTP (requires App Password)..."
  echo
  echo "To create a Gmail App Password:"
  echo "1. Go to https://myaccount.google.com/apppasswords"
  echo "2. Create an app password for 'Mail'"
  echo "3. Copy the 16-character password"
  echo

  read -p "Gmail address: " gmail_address
  read -sp "Gmail App Password: " gmail_password
  echo
  read -p "Email 'From' address (e.g., alerts@yourdomain.com): " email_from
  read -p "Email 'To' address (where to send reports): " email_to

  # Create msmtp config
  msmtp_config="# msmtp configuration for stock-market-summary
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account gmail
host           smtp.gmail.com
port           587
from           ${email_from}
user           ${gmail_address}
password       ${gmail_password}

account default : gmail"

  echo "$msmtp_config" | sudo -u "$run_user" tee "$user_home/.msmtprc" > /dev/null
  sudo chmod 600 "$user_home/.msmtprc"
  sudo chown "$run_user:$run_user" "$user_home/.msmtprc"
  echo_info "Email configuration saved."
else
  # Extract email settings from existing config
  email_from=$(grep -m1 "^from" "$user_home/.msmtprc" 2>/dev/null | awk '{print $2}' || echo "")
  read -p "Email 'To' address (where to send reports): " email_to
fi

echo

# Anthropic API key
echo "=============================================="
echo "  Anthropic API Configuration"
echo "=============================================="
echo
echo "Enter your Anthropic API key for AI-generated insights."
echo "(Get one at https://console.anthropic.com/)"
echo

read -sp "Anthropic API Key: " anthropic_key
echo
echo

# Watchlist setup
echo "=============================================="
echo "  Watchlist Configuration"
echo "=============================================="
echo
echo "A sample watchlist has been created at:"
echo "  /home/stock-market-summary/watchlist.conf"
echo
echo "You can edit this file to customize your categories and tickers."
echo

# Copy watchlist to user home
echo_info "Copying watchlist to $user_home/.watchlist.conf"
sudo cp /home/stock-market-summary/watchlist.conf "$user_home/.watchlist.conf"
sudo chown "$run_user:$run_user" "$user_home/.watchlist.conf"

# Create config file
echo_info "Creating configuration file..."
config_content="# Stock Market Summary Configuration
# Generated by install.sh on $(date)

# Email settings
email_to=\"${email_to}\"
email_from=\"${email_from}\"

# Anthropic API key
anthropic_api_key=\"${anthropic_key}\""

echo "$config_content" | sudo -u "$run_user" tee "$user_home/.stocksum.conf" > /dev/null
sudo chmod 600 "$user_home/.stocksum.conf"
sudo chown "$run_user:$run_user" "$user_home/.stocksum.conf"

echo

# Install script
echo "=============================================="
echo "  Installing Script"
echo "=============================================="
echo

echo_info "Installing stock_summary.sh to /usr/local/sbin/"
sudo cp /home/stock-market-summary/stock_summary.sh /usr/local/sbin/stock_summary.sh
sudo chmod 755 /usr/local/sbin/stock_summary.sh

# Create log directory
echo_info "Creating log directory..."
sudo mkdir -p /var/log/stock-summary
sudo chown "$run_user:$run_user" /var/log/stock-summary

echo

# Cron setup
echo "=============================================="
echo "  Cron Schedule Setup"
echo "=============================================="
echo
echo "Default schedule (US Eastern Time):"
echo "  - Market Open:  9:35 AM ET (Mon-Fri)"
echo "  - Intraday:    12:30 PM ET (Mon-Fri)"
echo "  - Market Close: 4:05 PM ET (Mon-Fri)"
echo

read -p "Install cron jobs with this schedule? [Y/n] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  cron_content="# Stock Market Summary - generated by install.sh
SHELL=/bin/bash
TZ=America/New_York

# Market open (9:35 AM ET - 5 min after open)
35 9 * * 1-5 /usr/local/sbin/stock_summary.sh open

# Intraday (12:30 PM ET)
30 12 * * 1-5 /usr/local/sbin/stock_summary.sh intra

# Market close (4:05 PM ET - 5 min after close)
5 16 * * 1-5 /usr/local/sbin/stock_summary.sh close"

  echo "$cron_content" | sudo -u "$run_user" crontab -
  echo_info "Cron jobs installed for user $run_user"
else
  echo_info "Skipping cron setup. You can manually add cron jobs later."
fi

echo

# Test run
echo "=============================================="
echo "  Testing"
echo "=============================================="
echo

read -p "Run a test to verify everything works? [Y/n] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo_info "Running test (this may take a moment)..."
  echo
  if sudo -u "$run_user" -H /usr/local/sbin/stock_summary.sh test; then
    echo
    echo_info "Test completed successfully!"
  else
    echo
    echo_warn "Test encountered issues. Check the output above."
  fi
fi

echo

# Summary
echo "=============================================="
echo "  Installation Complete!"
echo "=============================================="
echo
echo "Configuration files:"
echo "  - Config:    $user_home/.stocksum.conf"
echo "  - Watchlist: $user_home/.watchlist.conf"
echo "  - Email:     $user_home/.msmtprc"
echo
echo "Logs: /var/log/stock-summary/"
echo
echo "Commands:"
echo "  Test:    sudo -u $run_user -H /usr/local/sbin/stock_summary.sh test"
echo "  Manual:  sudo -u $run_user -H /usr/local/sbin/stock_summary.sh {open|intra|close}"
echo
echo "To edit your watchlist:"
echo "  sudo -u $run_user nano $user_home/.watchlist.conf"
echo
echo "To view cron jobs:"
echo "  sudo -u $run_user crontab -l"
echo
