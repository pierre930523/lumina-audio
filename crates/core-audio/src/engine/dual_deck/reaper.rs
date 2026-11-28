//! Background thread reaper and live decode thread guard.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::decoder::pcm::AudioDecoder;

enum ReaperMsg {
    Decode(JoinHandle<Option<Box<dyn AudioDecoder>>>),
    #[allow(dead_code)]
    Unit(JoinHandle<()>),
    Shutdown,
}

/// Off-control-path background thread reaper so `stop()`, `cancel_standby()`, `begin_skip_transition()`,
/// and `commit_opened_decoder()` never synchronously block on `JoinHandle::join()`.
pub(crate) struct ThreadReaper {
    tx: Mutex<Option<mpsc::Sender<ReaperMsg>>>,
    handle: Mutex<Option<JoinHandle<()>>>,
}

impl ThreadReaper {
    pub(crate) fn new() -> Self {
        let (tx, rx) = mpsc::channel::<ReaperMsg>();
        let handle = thread::Builder::new()
            .name("lumina-thread-reaper".to_string())
            .spawn(move || {
                while let Ok(msg) = rx.recv() {
                    match msg {
                        ReaperMsg::Decode(jh) => {
                            let _ = jh.join();
                        }
                        ReaperMsg::Unit(jh) => {
                            let _ = jh.join();
                        }
                        ReaperMsg::Shutdown => break,
                    }
                }
            })
            .ok();
        Self {
            tx: Mutex::new(Some(tx)),
            handle: Mutex::new(handle),
        }
    }

    pub(crate) fn retire_decode(&self, jh: JoinHandle<Option<Box<dyn AudioDecoder>>>) {
        if let Ok(guard) = self.tx.lock()
            && let Some(ref tx) = *guard
        {
            let _ = tx.send(ReaperMsg::Decode(jh));
        }
    }

    #[allow(dead_code)]
    pub(crate) fn retire_unit(&self, jh: JoinHandle<()>) {
        if let Ok(guard) = self.tx.lock()
            && let Some(ref tx) = *guard
        {
            let _ = tx.send(ReaperMsg::Unit(jh));
        }
    }

    pub(crate) fn shutdown(&self) {
        if let Ok(mut guard) = self.tx.lock()
            && let Some(tx) = guard.take()
        {
            let _ = tx.send(ReaperMsg::Shutdown);
        }
        if let Ok(mut h_guard) = self.handle.lock()
            && let Some(h) = h_guard.take()
        {
            let deadline = Instant::now() + Duration::from_secs(1);
            while !h.is_finished() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            if h.is_finished() {
                let _ = h.join();
            }
        }
    }
}

pub(crate) struct DecodeThreadGuard {
    counter: Arc<AtomicUsize>,
}

impl DecodeThreadGuard {
    pub(crate) fn new(counter: &Arc<AtomicUsize>) -> Self {
        counter.fetch_add(1, Ordering::AcqRel);
        Self {
            counter: Arc::clone(counter),
        }
    }
}

impl Drop for DecodeThreadGuard {
    fn drop(&mut self) {
        self.counter.fetch_sub(1, Ordering::AcqRel);
    }
}
