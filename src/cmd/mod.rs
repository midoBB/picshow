pub mod backup;
pub mod restore;
pub mod serve;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use reqwest::Client;
use tracing::{debug, info};

use crate::logging::LogLevel;

#[derive(Parser)]
#[command(
    author,
    version = env!("APP_VERSION"),
    about = "Picshow is a self-hosted image and video gallery",
    long_about = "Picshow is a self-hosted image and video gallery. It allows you to upload and organize your photos and videos. You can favorite images and videos. Picshow is built with Rust."
)]
pub struct Cli {
    #[arg(
        short = 'l',
        long = "log",
        global = true,
        value_enum,
        help = "The log level to use. This is optional and will default to the one specified in the config file."
    )]
    /// The log level to use
    pub log_level: Option<LogLevel>,
    #[command(subcommand)]
    /// The command to run
    pub command: Option<Commands>,
}

#[derive(Subcommand)]
pub enum Commands {
    #[command(about = "Backups the database to a .bak file")]
    Backup {
        #[arg(
            short,
            long,
            help = "The destination to save the backup to. This is optional and will default to the one specified in the config file."
        )]
        destination: Option<PathBuf>,
    },
    #[command(about = "Restores the database to the state in the provided .bak file")]
    Restore {
        #[arg(required = true)]
        backup_file: PathBuf,
    },
    #[command(about = "Runs the application")]
    Serve {
        #[arg(
            short,
            long,
            help = "The port to run the application on. This is optional and will default to the one specified in the config file."
        )]
        port: Option<u16>,
    },
}

pub(crate) enum InternalOP {
    Lock,
    Unlock,
}
pub(crate) async fn make_lock_request(
    config: &crate::config::AppConfig,
    op: InternalOP,
) -> Result<()> {
    let op = match op {
        InternalOP::Lock => "lock",
        InternalOP::Unlock => "unlock",
    };
    let client = Client::new();
    let url = format!(
        "http://localhost:{}/api/internal/{}/{}",
        config.port, op, config.lock_secret
    );

    let response = client.get(&url).send().await;
    if let Err(e) = response {
        if e.is_connect() {
            debug!("Application is not running");
            return Ok(());
        }
        return Err(e.into());
    }
    let response = response.map_err(|e| anyhow::anyhow!("HTTP request failed: {}", e))?;
    match response.status() {
        reqwest::StatusCode::NO_CONTENT => {
            info!("Database is {} during this operation", op);
            Ok(())
        }
        _ => Err(anyhow::anyhow!(
            "Failed to {} the database during this operation",
            op
        )),
    }
}
