# Stock Market Summary

A bash-based tool that sends AI-powered stock market summary emails 3x daily (market open, intraday, close). Features categorized watchlists, color-coded HTML reports, and daily progression tracking.

## Features

- **3x Daily Reports**: Automated emails at market open (9:35 AM ET), intraday (12:30 PM ET), and close (4:05 PM ET)
- **AI Insights**: Claude-generated market analysis and commentary
- **Categorized Watchlist**: Organize tickers by sector (Big Tech, Crypto, Energy, etc.)
- **HTML Emails**: Color-coded tables (green for gains, red for losses)
- **Daily Progression**: Track how categories moved throughout the day (open → intraday → close)
- **Market Breadth**: Visual bar showing advancing vs declining tickers
- **Smart Scheduling**: Automatically skips weekends and US market holidays

## Requirements

- Linux/macOS with bash
- `curl`, `jq`, `bc` (for data fetching and calculations)
- `msmtp` (for sending emails)
- Anthropic API key (for AI insights)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/freq0ut/stock-market-summary.git
   cd stock-market-summary
   ```

2. Run the installer:
   ```bash
   ./install.sh
   ```

   The installer will:
   - Install dependencies (`curl`, `jq`, `bc`, `msmtp`)
   - Prompt for your Anthropic API key
   - Prompt for email configuration
   - Set up cron jobs for automated reports

3. Or configure manually:
   ```bash
   cp stocksum.conf.example stocksum.conf
   # Edit stocksum.conf with your settings
   ```

## Configuration

### stocksum.conf

Create this file with your settings (not tracked by git):

```bash
# Email settings
email_from="alerts@your-domain.com"

# Test mode email (only this address receives test reports)
email_test="your-email@example.com"

# Email recipients with cadence
# Format: "email|cadence" where cadence is: all, open, intra, close
# "all" means all reports (open, intra, close)
email_recipients=(
  "your-email@example.com|all"           # Receives all 3 daily reports
  "someone-else@example.com|close"       # Only receives market close report
)

# Anthropic API key for AI insights
anthropic_api_key="sk-ant-api03-your-key-here"
```

**Cadence options:**
- `all` - Receive all reports (open, intra, close)
- `open` - Receive only market open report
- `intra` - Receive only intraday report
- `close` - Receive only market close report
- `open,close` - Receive multiple specific reports (comma-separated)

**Note:** Recipients are BCC'd so they cannot see other recipients on the email.

### watchlist.conf

Customize your watchlist by category:

```bash
# Format: CATEGORY:TICKER1,TICKER2,TICKER3
# Spaces allowed in category names, avoid commas and ampersands

INDICES:SPY,QQQ,DIA,IWM
BIG TECH:AAPL,AMZN,GOOGL,META,MSFT,NVDA,TSLA
CRYPTO BLUECHIP:BTC-USD,ETH-USD,SOL-USD
SEMICONDUCTORS:AMD,INTC,MU,TSM,AVGO
ENERGY:XOM,CVX,OXY
```

**Notes:**
- Crypto tickers use `-USD` suffix (Yahoo Finance format)
- Futures use `=F` suffix (e.g., `GC=F` for gold)
- Category names can have spaces but not commas or ampersands

### Email Setup (msmtp)

Create `~/.msmtprc` for SMTP configuration:

```bash
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           your-email@gmail.com
user           your-email@gmail.com
password       your-app-password

account default : gmail
```

Set permissions: `chmod 600 ~/.msmtprc`

**Gmail users**: Use an [App Password](https://support.google.com/accounts/answer/185833), not your regular password.

## Usage

### Manual runs

```bash
# Run specific report type
./stock_summary.sh open
./stock_summary.sh intra
./stock_summary.sh close

# Test mode (prints to stdout, doesn't send email)
./stock_summary.sh test
```

### Cron schedule

The installer sets up these cron jobs (US Eastern time):

```cron
SHELL=/bin/bash
TZ=America/New_York

# Market open (9:35 AM ET - 5 min after open)
35 9 * * 1-5 /path/to/stock_summary.sh open

# Intraday (12:30 PM ET)
30 12 * * 1-5 /path/to/stock_summary.sh intra

# Market close (4:05 PM ET - 5 min after close)
5 16 * * 1-5 /path/to/stock_summary.sh close
```

## Email Report Structure

Each email includes:

1. **Summary Box**
   - Best/worst performing ticker
   - Top 3 and bottom 3 performing categories
   - Market breadth bar (advancing/declining/unchanged)

2. **Category Tables**
   - Category name with average % change
   - Daily progression (Open → Intraday → Close values)
   - Individual tickers sorted by % change
   - Color-coded: green (+), red (-), gray (flat)

3. **AI Insights**
   - Market sentiment analysis
   - Notable movers and catalysts
   - Sector observations
   - Key takeaways

## Daily Progression

As the day progresses, each report builds on previous data:

- **Open report**: Shows current values only
- **Intraday report**: Shows current + Open values
- **Close report**: Shows current + Intraday + Open values

Data resets automatically each trading day.

## Holiday Detection

The script automatically skips US market holidays:
- New Year's Day
- MLK Day
- Presidents Day
- Good Friday
- Memorial Day
- Juneteenth
- Independence Day
- Labor Day
- Thanksgiving
- Christmas

When holidays fall on weekends, the observed day (Friday or Monday) is skipped.

## Logs

Logs are stored in the `logs/` directory:
- `run_YYYY-MM-DD_HHMMSS.log` - Execution logs
- `daily_YYYY-MM-DD.dat` - Daily progression data

## Troubleshooting

**No email received:**
- Check `~/.msmtp.log` for SMTP errors
- Verify `stocksum.conf` has correct email settings
- Test with `./stock_summary.sh test` first

**Missing data for tickers:**
- Verify ticker symbols are valid on Yahoo Finance
- Check logs for "Failed to fetch" errors
- Some tickers may be delisted or renamed

**AI insights unavailable:**
- Verify Anthropic API key in `stocksum.conf`
- Check API key has sufficient credits

## License

MIT License - feel free to modify and distribute.

## Acknowledgments

Built with assistance from Claude (Anthropic).
