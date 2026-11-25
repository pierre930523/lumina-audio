use core_audio::buffer::SpscRingBuffer;
use std::thread;

#[test]
fn test_spsc_ring_buffer_capacity_power_of_two() {
    let (p, c) = SpscRingBuffer::<f64>::new(1000);
    assert_eq!(p.capacity(), 1024);
    assert_eq!(c.capacity(), 1024);

    let (p2, _) = SpscRingBuffer::<f64>::new(1024);
    assert_eq!(p2.capacity(), 1024);

    let (p3, _) = SpscRingBuffer::<f64>::new(1025);
    assert_eq!(p3.capacity(), 2048);
}

#[test]
fn test_spsc_ring_buffer_empty_and_full_conditions() {
    let (mut p, mut c) = SpscRingBuffer::<i32>::new(64);
    assert!(c.is_empty());
    assert_eq!(c.available_read(), 0);
    assert_eq!(p.available_write(), 64);

    // Push 64 items (exact capacity)
    let data: Vec<i32> = (0..64).collect();
    let written = p.push_slice(&data);
    assert_eq!(written, 64);
    assert!(p.is_full());
    assert_eq!(p.available_write(), 0);

    // Further push should write 0 items
    let extra = [999];
    assert_eq!(p.push_slice(&extra), 0);

    // Pop 32 items
    let mut out = [0i32; 32];
    let read = c.pop_slice(&mut out);
    assert_eq!(read, 32);
    assert_eq!(&out[..], &(0..32).collect::<Vec<i32>>()[..]);

    assert_eq!(p.available_write(), 32);
    assert_eq!(c.available_read(), 32);

    // Pop remaining 32 items
    let read2 = c.pop_slice(&mut out);
    assert_eq!(read2, 32);
    assert_eq!(&out[..], &(32..64).collect::<Vec<i32>>()[..]);

    assert!(c.is_empty());
    assert_eq!(c.pop_slice(&mut out), 0);
}

#[test]
fn test_spsc_ring_buffer_wraparound() {
    let (mut p, mut c) = SpscRingBuffer::<u32>::new(8);
    // Push 6, pop 6 multiple times to cause multiple wraparounds of head & tail
    for round in 0..100 {
        let items: Vec<u32> = (0..6).map(|i| round * 10 + i).collect();
        let written = p.push_slice(&items);
        assert_eq!(written, 6);

        let mut read_buf = [0u32; 6];
        let read = c.pop_slice(&mut read_buf);
        assert_eq!(read, 6);
        assert_eq!(&read_buf[..], &items[..]);
    }
}

#[test]
fn test_spsc_concurrency_stress_2_million_frames() {
    const TOTAL_FRAMES: usize = 2_000_000;
    const CAPACITY: usize = 16384;

    let (mut producer, mut consumer) = SpscRingBuffer::<u64>::new(CAPACITY);

    let producer_handle = thread::spawn(move || {
        let mut frames_sent = 0;
        let mut chunk_buf = [0u64; 256];

        while frames_sent < TOTAL_FRAMES {
            let chunk_size = ((frames_sent % 128) + 64).min(TOTAL_FRAMES - frames_sent);
            for (i, slot) in chunk_buf.iter_mut().enumerate().take(chunk_size) {
                *slot = (frames_sent + i) as u64;
            }

            let mut offset = 0;
            while offset < chunk_size {
                let written = producer.push_slice(&chunk_buf[offset..chunk_size]);
                if written == 0 {
                    thread::yield_now();
                } else {
                    offset += written;
                }
            }

            frames_sent += chunk_size;
        }
    });

    let consumer_handle = thread::spawn(move || {
        let mut expected = 0u64;
        let mut read_buf = [0u64; 512];

        while expected < TOTAL_FRAMES as u64 {
            let read = consumer.pop_slice(&mut read_buf);
            if read == 0 {
                thread::yield_now();
            } else {
                for &actual in read_buf.iter().take(read) {
                    assert_eq!(
                        actual, expected,
                        "Data corruption/reordering in SPSC queue at frame {expected}: got {actual}"
                    );
                    expected += 1;
                }
            }
        }
    });

    producer_handle.join().expect("Producer thread panicked");
    consumer_handle.join().expect("Consumer thread panicked");
}

#[test]
fn test_spsc_flush_and_ack_discards_stale_items() {
    let (mut p, mut c) = SpscRingBuffer::<u32>::new(32);
    let ctrl = p.control();

    assert_eq!(p.epoch(), 0);
    assert_eq!(c.epoch(), 0);
    assert!(ctrl.is_flushed());

    // Push epoch-0 items.
    let stale: Vec<u32> = (100..116).collect();
    assert_eq!(p.push_slice(&stale), 16);
    assert_eq!(c.available_read(), 16);

    // Pop 4, leaving 12 stale items.
    let mut head_out = [0u32; 4];
    assert_eq!(c.pop_slice(&mut head_out), 4);
    assert_eq!(head_out, [100, 101, 102, 103]);

    // Request flush (epoch 0 -> 1).
    let req_epoch = ctrl.request_flush();
    assert_eq!(req_epoch, 1);
    assert_eq!(ctrl.epoch(), 1);
    assert!(p.has_pending_flush());
    assert!(c.has_pending_flush());
    assert!(!ctrl.is_flushed());

    // Consumer must not expose stale items, and Producer must refuse stale pushes.
    assert_eq!(c.available_read(), 0);
    assert_eq!(p.available_write(), 0);
    assert_eq!(p.push_slice(&[999, 1000]), 0);

    // Consumer flushes and discards the 12 stale items.
    let discarded = c.flush_and_ack();
    assert_eq!(discarded, 12);
    assert_eq!(c.epoch(), 1);
    assert!(ctrl.is_consumer_synced());
    assert!(!ctrl.is_flushed()); // Producer hasn't synced yet.

    // Producer syncs to epoch 1 and pushes fresh items.
    assert_eq!(p.sync_epoch(), 1);
    assert_eq!(p.epoch(), 1);
    assert!(ctrl.is_flushed());

    let fresh: Vec<u32> = (200..210).collect();
    assert_eq!(p.push_slice(&fresh), 10);
    assert_eq!(c.available_read(), 10);

    let mut out = [0u32; 10];
    assert_eq!(c.pop_slice(&mut out), 10);
    assert_eq!(out, fresh.as_slice());
}

#[test]
fn test_spsc_paused_consumer_producer_prefills_before_consumer_flushes() {
    let (mut p, mut c) = SpscRingBuffer::<u32>::new(64);
    let ctrl = c.control();

    // Pre-seek audio pushed in epoch 0 while consumer hasn't drained it yet.
    assert_eq!(p.push_slice(&(1..=20).collect::<Vec<_>>()), 20);
    let mut partial = [0u32; 5];
    assert_eq!(c.pop_slice(&mut partial), 5);
    assert_eq!(partial, [1, 2, 3, 4, 5]);

    // Seek occurs while consumer is paused (consumer does NOT wake up yet).
    assert_eq!(ctrl.request_flush(), 1);
    assert_eq!(p.sync_epoch(), 1);

    // Producer pre-fills epoch-1 audio before consumer ever flushes!
    let post_seek: Vec<u32> = (1000..1012).collect();
    assert_eq!(p.push_slice(&post_seek), 12);

    // Non-destructive available_read() sees only the 12 epoch-1 items (never the 15 stale ones).
    assert_eq!(c.available_read(), 12);

    // First pop_slice auto-syncs barrier, discards 15 stale items, and returns ONLY epoch-1 items.
    let mut out = [0u32; 16];
    let n = c.pop_slice(&mut out);
    assert_eq!(n, 12);
    assert_eq!(&out[..12], post_seek.as_slice());
    assert!(ctrl.is_flushed());
    assert!(c.is_empty());

    // Subsequent flush_and_ack discards 0 since pop_slice already crossed the barrier.
    assert_eq!(c.flush_and_ack(), 0);
}

#[test]
fn test_spsc_multiple_flushes_before_consumer_wakes() {
    let (mut p, mut c) = SpscRingBuffer::<u32>::new(64);
    let ctrl = p.control();

    // Epoch 0 writes.
    assert_eq!(p.push_slice(&[1, 2, 3, 4, 5]), 5);

    // Rapid seek 1 -> epoch 1 writes.
    assert_eq!(ctrl.request_flush(), 1);
    assert_eq!(p.sync_epoch(), 1);
    assert_eq!(p.push_slice(&[10, 11, 12]), 3);

    // Rapid seek 2 -> epoch 2 writes, all before consumer wakes!
    assert_eq!(ctrl.request_flush(), 2);
    assert_eq!(p.sync_epoch(), 2);
    assert_eq!(p.push_slice(&[20, 21, 22, 23]), 4);

    // Consumer wakes up and sees only the 4 epoch-2 items.
    assert_eq!(c.available_read(), 4);
    let discarded = c.flush_and_ack();
    assert_eq!(discarded, 8); // 5 from epoch 0 + 3 from epoch 1
    assert_eq!(c.available_read(), 4);

    let mut out = [0u32; 8];
    assert_eq!(c.pop_slice(&mut out), 4);
    assert_eq!(&out[..4], &[20, 21, 22, 23]);
}

#[test]
fn test_spsc_push_with_epoch_rejects_stale_and_syncs_current() {
    let (mut p, mut c) = SpscRingBuffer::<u64>::new(16);
    let ctrl = p.control();

    assert_eq!(p.push_with_epoch(0, &[1, 2, 3]), Ok(3));

    // Request flush -> epoch 1.
    let e1 = ctrl.request_flush();
    assert_eq!(e1, 1);

    // Stale epoch 0 must be rejected with Err(1).
    assert_eq!(p.push_with_epoch(0, &[4, 5]), Err(1));

    // Matching epoch 1 auto-syncs producer and writes cleanly.
    assert_eq!(p.push_with_epoch(1, &[100, 101]), Ok(2));
    assert_eq!(p.epoch(), 1);

    // Bump again -> epoch 2; epoch 1 rejected with Err(2).
    assert_eq!(ctrl.request_flush(), 2);
    assert_eq!(p.push_with_epoch(1, &[102]), Err(2));
    assert_eq!(p.push_with_epoch(2, &[200]), Ok(1));

    let mut out = [0u64; 4];
    assert_eq!(c.pop_slice(&mut out), 1);
    assert_eq!(out[0], 200);
}

#[test]
fn test_spsc_clear_empties_buffer_across_wraparound() {
    let (mut p, mut c) = SpscRingBuffer::<u32>::new(16);

    // Advance head & tail near wraparound boundary.
    let chunk = [1u32; 12];
    let mut tmp = [0u32; 12];
    for _ in 0..3 {
        assert_eq!(p.push_slice(&chunk), 12);
        assert_eq!(c.pop_slice(&mut tmp), 12);
    }

    // Push 14 elements that wrap across index 16.
    let wrapped: Vec<u32> = (500..514).collect();
    assert_eq!(p.push_slice(&wrapped), 14);
    assert_eq!(c.available_read(), 14);

    // Clear on consumer empties all 14 elements cleanly.
    assert_eq!(c.clear(), 14);
    assert_eq!(c.available_read(), 0);
    assert!(c.is_empty());
    assert_eq!(p.available_write(), 16);

    // Ring remains reusable after clear.
    let next: Vec<u32> = (600..616).collect();
    assert_eq!(p.push_slice(&next), 16);
    let mut out = [0u32; 16];
    assert_eq!(c.pop_slice(&mut out), 16);
    assert_eq!(out, next.as_slice());
}

#[test]
fn test_spsc_concurrent_seek_epoch_stress() {
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::Arc;

    const MIN_ELEMENTS: usize = 600_000;
    const TARGET_FLUSHES: usize = 600;
    const CAPACITY: usize = 4096;

    let (mut producer, mut consumer) = SpscRingBuffer::<u64>::new(CAPACITY);
    let ctrl_coord = producer.control();
    let ctrl_cons = consumer.control();

    let done = Arc::new(AtomicBool::new(false));
    let done_coord = Arc::clone(&done);
    let prod_done = Arc::new(AtomicBool::new(false));
    let prod_done_flag = Arc::clone(&prod_done);
    let flush_count = Arc::new(AtomicU64::new(0));
    let flush_count_coord = Arc::clone(&flush_count);

    let coord_handle = thread::spawn(move || {
        for _ in 0..TARGET_FLUSHES {
            ctrl_coord.request_flush();
            flush_count_coord.fetch_add(1, Ordering::Release);
            thread::yield_now();
        }
        done_coord.store(true, Ordering::Release);
    });

    let prod_handle = thread::spawn(move || {
        let mut total_pushed = 0usize;
        let mut current_epoch = 0u64;
        let mut seq_in_epoch = 0u64;
        let mut batch = [0u64; 128];

        while total_pushed < MIN_ELEMENTS || !done.load(Ordering::Acquire) {
            if producer.has_pending_flush() {
                current_epoch = producer.sync_epoch();
                seq_in_epoch = 0;
            }
            for (i, slot) in batch.iter_mut().enumerate() {
                *slot = (current_epoch << 32) | (seq_in_epoch + i as u64);
            }
            match producer.push_with_epoch(current_epoch, &batch) {
                Ok(0) => {
                    thread::yield_now();
                }
                Ok(n) => {
                    seq_in_epoch += n as u64;
                    total_pushed += n;
                }
                Err(_) => {
                    current_epoch = producer.sync_epoch();
                    seq_in_epoch = 0;
                }
            }
        }
        // Push one final sentinel batch in the very latest epoch so consumer knows final state.
        let final_epoch = producer.sync_epoch();
        if final_epoch != current_epoch {
            seq_in_epoch = 0;
        }
        let sentinel = (final_epoch << 32) | seq_in_epoch;
        while producer.push_with_epoch(final_epoch, &[sentinel]).is_err() {
            let e = producer.sync_epoch();
            let s = e << 32;
            if producer.push_with_epoch(e, &[s]).is_ok() {
                break;
            }
        }
        prod_done_flag.store(true, Ordering::Release);
        total_pushed
    });

    let cons_handle = thread::spawn(move || {
        let mut last_epoch = 0u64;
        let mut expected_seq = 0u64;
        let mut read_buf = [0u64; 192];
        let mut total_read = 0usize;

        loop {
            if consumer.has_pending_flush() {
                consumer.flush_and_ack();
                let new_epoch = consumer.epoch();
                assert!(
                    new_epoch >= last_epoch,
                    "Consumer epoch regressed: {new_epoch} < {last_epoch}"
                );
                if new_epoch > last_epoch {
                    last_epoch = new_epoch;
                    expected_seq = 0;
                }
            }

            let n = consumer.pop_slice(&mut read_buf);
            if n == 0 {
                if prod_done.load(Ordering::Acquire)
                    && flush_count.load(Ordering::Acquire) as usize >= TARGET_FLUSHES
                    && ctrl_cons.is_flushed()
                    && consumer.is_empty()
                {
                    break;
                }
                thread::yield_now();
                continue;
            }

            for &val in &read_buf[..n] {
                let item_epoch = val >> 32;
                let item_seq = val & 0xFFFF_FFFF;
                assert!(
                    item_epoch >= last_epoch,
                    "Stale epoch leaked into consumer: item_epoch={item_epoch} < last_epoch={last_epoch}"
                );
                if item_epoch > last_epoch {
                    last_epoch = item_epoch;
                    expected_seq = 0;
                }
                assert_eq!(
                    item_seq, expected_seq,
                    "Sequence gap/corruption in epoch {item_epoch}: expected {expected_seq}, got {item_seq}"
                );
                expected_seq += 1;
            }
            total_read += n;
        }
        total_read
    });

    coord_handle.join().expect("Coordinator panicked");
    let pushed = prod_handle.join().expect("Producer panicked");
    let _read = cons_handle.join().expect("Consumer panicked");
    assert!(pushed >= MIN_ELEMENTS);
}

#[test]
fn test_spsc_clear_races_sync_epoch_and_push_slice() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    const CAPACITY: usize = 1024;
    let (mut producer, mut consumer) = SpscRingBuffer::<u64>::new(CAPACITY);
    let done = Arc::new(AtomicBool::new(false));

    let done_prod = Arc::clone(&done);
    let prod_handle = thread::spawn(move || {
        let chunk = [42u64; 32];
        let mut count = 0usize;
        while !done_prod.load(Ordering::Acquire) && count < 20_000 {
            producer.request_flush();
            producer.sync_epoch();
            let _ = producer.push_slice(&chunk);
            count += 1;
            if count.is_multiple_of(64) {
                thread::yield_now();
            }
        }
        done_prod.store(true, Ordering::Release);
        count
    });

    let done_cons = Arc::clone(&done);
    let cons_handle = thread::spawn(move || {
        let mut clears = 0usize;
        let mut out = [0u64; 64];
        let start = Instant::now();
        while !done_cons.load(Ordering::Acquire) && start.elapsed() < Duration::from_secs(3) {
            let _ = consumer.clear();
            clears += 1;
            // Interleave with reading to ensure consumer monotonic invariant holds
            let _ = consumer.pop_slice(&mut out);
            if clears.is_multiple_of(128) {
                thread::yield_now();
            }
        }
        done_cons.store(true, Ordering::Release);
        clears
    });

    let p_count = prod_handle.join().expect("Producer panicked");
    let c_count = cons_handle.join().expect("Consumer panicked");
    assert!(p_count > 0);
    assert!(c_count > 0);
}
