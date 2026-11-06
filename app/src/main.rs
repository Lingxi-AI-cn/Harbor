use std::{fs, os::unix::fs::{DirBuilderExt, OpenOptionsExt}, process::{Command, ExitCode}, io::Write, time::{SystemTime, UNIX_EPOCH}};

// Embed the native executable so the Cargo output is a portable, standalone binary.
fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code as u8),
        Err(error) => { eprintln!("Harbor could not start: {error}"); ExitCode::FAILURE }
    }
}

fn run() -> std::io::Result<i32> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("harbor-{}-{stamp}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&dir)?;
    let binary = dir.join("Harbor");
    let outcome = (|| {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o700).open(&binary)?;
        file.write_all(include_bytes!(concat!(env!("OUT_DIR"), "/Harbor")))?;
        drop(file);
        {
            let mut command = Command::new(&binary);
            if let Some(resources) = option_env!("HARBOR_GHOSTTY_RESOURCES") {
                if std::env::var_os("GHOSTTY_RESOURCES_DIR").is_none() { command.env("GHOSTTY_RESOURCES_DIR", resources); }
            }
            command.args(std::env::args_os().skip(1)).status()
        }
    })();
    let _ = fs::remove_dir_all(&dir);
    Ok(outcome?.code().unwrap_or(1))
}
