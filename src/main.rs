use anyhow::Result;
use clap::{CommandFactory, Parser};
use picshow::cmd::backup::handle_backup;
use picshow::cmd::restore::handle_restore;
use picshow::cmd::serve::handle_serve;
use picshow::cmd::{Cli, Commands};
use picshow::config::AppConfig;
use picshow::logging;
use picshow::server::first_run;
use tracing::{error, warn};

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = AppConfig::try_load();
    let should_run_first_time = !AppConfig::config_exists() || config.is_err();
    if should_run_first_time {
        logging::init_logging(cli.log_level, None);
    } else {
        logging::init_logging(cli.log_level, Some(config.as_ref().map_err(|e| anyhow::anyhow!("Failed to access config: {}", e))?.log_level));
    }
    let mut config = match config {
        Ok(cfg) => cfg,
        Err(e) => {
            error!("Error parsing configuration: {}", e);
            AppConfig::default()
        }
    };
    if should_run_first_time {
        warn!("First time running the application, starting first run server");
        config = first_run::run_server(config.clone()).await?;
    }
    if let Some(cmd) = cli.command {
        match cmd {
            Commands::Backup { destination } => {
                let backup_res = handle_backup(config, destination).await;
                if let Err(e) = backup_res {
                    error!("Error running backup: {}", e);
                    std::process::exit(1);
                }
            }

            Commands::Restore { backup_file } => {
                let restore_res = handle_restore(config, backup_file).await;
                if let Err(e) = restore_res {
                    error!("Error running restore: {}", e);
                    std::process::exit(1);
                }
            }

            Commands::Serve { port } => handle_serve(&config, port).await?,
        }
    } else {
        if let Err(e) = Cli::command().print_long_help() {
            error!("Failed to print help: {}", e);
            std::process::exit(1);
        }
    }
    Ok(())
}
