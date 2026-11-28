use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use core_providers::{
    DirectoryScanner, TagInspectionReport, format_tag_inspection_report, inspect_audio_tags,
};

fn print_usage() {
    eprintln!("Usage: tag_debug [--json] <audio-file-or-dir>...");
    eprintln!();
    eprintln!("Inspects raw audio tag blocks, detected encodings, final parsed metadata,");
    eprintln!("and computed AlbumKey values. When given a directory or multiple files,");
    eprintln!("also flags AlbumKey mismatches within the same effective folder.");
}

fn main() -> ExitCode {
    let mut json_mode = false;
    let mut inputs: Vec<PathBuf> = Vec::new();

    for arg in env::args().skip(1) {
        match arg.as_str() {
            "--json" | "-j" => json_mode = true,
            "--help" | "-h" => {
                print_usage();
                return ExitCode::SUCCESS;
            }
            _ => inputs.push(PathBuf::from(arg)),
        }
    }

    if inputs.is_empty() {
        print_usage();
        return ExitCode::from(2);
    }

    let mut targets: Vec<PathBuf> = Vec::new();
    let mut scanner = DirectoryScanner::new(false);
    for p in inputs {
        if p.is_dir() {
            let mut found = scanner.scan_directory(&p);
            found.sort();
            targets.extend(found);
        } else {
            targets.push(p);
        }
    }

    if targets.is_empty() {
        eprintln!("No scannable audio files found.");
        return ExitCode::from(1);
    }

    let mut reports: Vec<TagInspectionReport> = Vec::new();
    let mut had_error = false;

    for target in &targets {
        match inspect_audio_tags(target) {
            Ok(report) => reports.push(report),
            Err(e) => {
                eprintln!("ERROR inspecting {}: {e}", target.display());
                had_error = true;
            }
        }
    }

    // Group reports by effective_dir_key to detect accidental album splitting inside one folder.
    type AlbumKeyGroups = BTreeMap<(String, String), Vec<String>>;
    let mut by_dir: BTreeMap<String, AlbumKeyGroups> = BTreeMap::new();
    for r in &reports {
        let dir = r.album_key.effective_dir_key.clone();
        let key = (
            r.album_key.group_artist_key.clone(),
            r.album_key.group_album_key.clone(),
        );
        by_dir
            .entry(dir)
            .or_default()
            .entry(key)
            .or_default()
            .push(r.file_path.clone());
    }

    let mismatches: Vec<(String, AlbumKeyGroups)> = by_dir
        .into_iter()
        .filter(|(_, keys)| keys.len() > 1)
        .collect();

    if json_mode {
        if reports.len() == 1 && mismatches.is_empty() {
            match serde_json::to_string_pretty(&reports[0]) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("JSON serialization error: {e}");
                    return ExitCode::from(1);
                }
            }
        } else {
            let payload = serde_json::json!({
                "reports": reports,
                "folder_album_key_mismatches": mismatches.iter().map(|(dir, groups)| {
                    serde_json::json!({
                        "effective_dir_key": dir,
                        "distinct_album_keys": groups.iter().map(|((art, alb), files)| {
                            serde_json::json!({
                                "group_artist_key": art,
                                "group_album_key": alb,
                                "files": files,
                            })
                        }).collect::<Vec<_>>(),
                    })
                }).collect::<Vec<_>>(),
            });
            match serde_json::to_string_pretty(&payload) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("JSON serialization error: {e}");
                    return ExitCode::from(1);
                }
            }
        }
    } else {
        for (i, r) in reports.iter().enumerate() {
            if i > 0 {
                println!();
            }
            print!("{}", format_tag_inspection_report(r));
        }
        if !mismatches.is_empty() {
            println!("\n=== [ALBUM KEY MISMATCH WARNING] ===");
            for (dir, groups) in &mismatches {
                println!(
                    "Folder '{dir}' produced {} distinct AlbumKeys:",
                    groups.len()
                );
                for ((art, alb), files) in groups {
                    println!("  * ({art:?}, {alb:?}) -> {} file(s):", files.len());
                    for f in files {
                        println!("      - {f}");
                    }
                }
            }
        }
    }

    if had_error {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
