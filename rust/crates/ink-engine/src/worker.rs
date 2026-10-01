use super::{
    Arc, Condvar, EngineError, EngineState, JoinHandle, Mutex, PacketQueue, PoisonError,
    QueueOutcome, consume_packet, decode, lock_recover, thread,
};

#[derive(Debug)]
pub(super) struct WorkerControl {
    pub(super) queue: PacketQueue,
    pub(super) shutdown: bool,
    pub(super) busy: bool,
}

#[derive(Debug)]
pub(super) struct RenderWorker {
    control: Arc<(Mutex<WorkerControl>, Condvar)>,
    state: Arc<Mutex<EngineState>>,
    join: Option<JoinHandle<()>>,
}

impl RenderWorker {
    pub(super) fn new(state: Arc<Mutex<EngineState>>) -> Result<Self, EngineError> {
        let control = Arc::new((
            Mutex::new(WorkerControl {
                queue: PacketQueue::new(1024),
                shutdown: false,
                busy: false,
            }),
            Condvar::new(),
        ));
        let worker_control = Arc::clone(&control);
        let worker_state = Arc::clone(&state);
        let join = thread::Builder::new()
            .name("project-ink-render".into())
            .spawn(move || render_worker_loop(worker_control, worker_state))
            .map_err(|error| EngineError::WorkerUnavailable(error.to_string()))?;
        Ok(Self {
            control,
            state,
            join: Some(join),
        })
    }

    pub(super) fn enqueue(&self, bytes: Vec<u8>) -> Result<QueueOutcome, EngineError> {
        Self::enqueue_pointer_packet(&self.control, bytes)
    }

    pub(super) fn enqueue_pointer_packet(
        control: &Arc<(Mutex<WorkerControl>, Condvar)>,
        bytes: Vec<u8>,
    ) -> Result<QueueOutcome, EngineError> {
        let (lock, wake) = &**control;
        let mut control = lock_recover(lock);
        let mut pending_packet = bytes;
        loop {
            if control.shutdown {
                return Err(EngineError::WorkerUnavailable(
                    "render worker is closed".into(),
                ));
            }
            match control.queue.push_preserving_on_error(pending_packet) {
                Ok(outcome) => {
                    if outcome == QueueOutcome::Enqueued {
                        wake.notify_one();
                    }
                    return Ok(outcome);
                }
                Err((ink_input::PacketError::QueueFull, packet)) => {
                    // Confirmed input is document data, not a disposable live
                    // preview. Keep the packet bounded at the queue boundary
                    // and wait for the CPU renderer to free a slot instead of
                    // rejecting the UI call and canceling the active stroke.
                    pending_packet = packet;
                    control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
                }
                Err((error, _packet)) => return Err(EngineError::Packet(error)),
            }
        }
    }

    pub(super) fn flush(&self) {
        let (lock, wake) = &*self.control;
        let mut control = lock_recover(lock);
        while !control.queue.is_empty() || control.busy {
            control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
        }
    }

    pub(super) fn take_error(&self) -> Option<String> {
        lock_recover(&self.state).worker_error.take()
    }

    pub(super) fn shutdown(&mut self) {
        let (lock, wake) = &*self.control;
        {
            let mut control = lock_recover(lock);
            control.shutdown = true;
            wake.notify_all();
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for RenderWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_worker_loop(
    control: Arc<(Mutex<WorkerControl>, Condvar)>,
    state: Arc<Mutex<EngineState>>,
) {
    loop {
        let bytes = {
            let (lock, wake) = &*control;
            let mut control = lock_recover(lock);
            while control.queue.is_empty() && !control.shutdown {
                control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
            }
            if control.queue.is_empty() && control.shutdown {
                break;
            }
            control.busy = true;
            control.queue.pop()
        };

        if let Some(bytes) = bytes {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                decode(&bytes)
                    .map_err(|error| error.to_string())
                    .and_then(|packet| {
                        consume_packet(&mut lock_recover(&state), packet)
                            .map_err(|error| error.to_string())
                    })
            }));
            let error = match result {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error),
                Err(_) => Some("render worker rejected a panicking packet".to_string()),
            };
            if let Some(error) = error {
                eprintln!("Project Ink render worker error: {error}");
                lock_recover(&state).worker_error = Some(error);
            }
        }

        let (lock, wake) = &*control;
        let mut control = lock_recover(lock);
        control.busy = false;
        wake.notify_all();
    }
}
