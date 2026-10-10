//! oxpkg: the package CLI. Thin client over intentd's package ops —
//! the daemon owns the package store (/data/ox/apps), the manifest
//! validation, and the spawn resolution; oxpkg just carries requests.
//!
//!   oxpkg install <src-dir>   install a staged .oxp directory
//!   oxpkg remove <app>        remove an installed package
//!   oxpkg list                installed packages (+ running)
//!   oxpkg start <app>         launch an app by name
//!
//! Exit 0 = the daemon reported ok; exit 1 = error (the error string
//! is printed). Logs to the console so s6 selftests capture output.
use ox_ipc::Client;
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;

fn sock_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("intentd.sock")
}

fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (op, payload) = match args.as_slice() {
        [op, src] if op == "install" => ("install", json!({ "src": src })),
        [op, app] if op == "remove" => ("remove", json!({ "app": app })),
        [op, app] if op == "start" => ("start", json!({ "app": app })),
        [op] if op == "list" => ("list", json!(null)),
        _ => {
            eprintln!("usage: oxpkg install <src> | remove <app> | list | start <app>");
            std::process::exit(2);
        }
    };
    let mut cl = None;
    for _ in 0..50 {
        match Client::connect(sock_path()) {
            Ok(c) => {
                cl = Some(c);
                break;
            }
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
    let Some(mut cl) = cl else {
        eprintln!("oxpkg: intentd not reachable");
        std::process::exit(1);
    };
    match cl.request(op, payload) {
        Ok(resp) if resp.error.is_none() => {
            println!(
                "oxpkg: {} ok {}",
                op,
                resp.payload.map(|p| p.to_string()).unwrap_or_default()
            );
            Ok(())
        }
        Ok(resp) => {
            eprintln!(
                "oxpkg: {} refused: {}",
                op,
                resp.error.as_deref().unwrap_or("unknown")
            );
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("oxpkg: {} failed: {e}", op);
            std::process::exit(1);
        }
    }
}
