"""
DSP reference models for 64-bit Parametric EQ, Headphone Crossfeed,
ReplayGain normalization, peak limiter, and Signal Path classification.
Includes lock-free SPSC circular ring buffer and DSP pipeline bypass controllers.
"""
import cmath
import math
from typing import Dict, Any, List, Optional, Tuple, Union


def calculate_biquad_peaking(
    freq_hz: float,
    gain_db: float,
    q_factor: float,
    sample_rate_hz: float = 48000.0,
) -> Dict[str, float]:
    """
    Computes biquad peaking EQ filter coefficients using the Audio EQ Cookbook formula.
    H(s) = (s^2 + s*(A/Q) + 1) / (s^2 + s/(A*Q) + 1)
    """
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * (freq_hz / sample_rate_hz)
    alpha = math.sin(w0) / (2.0 * max(q_factor, 0.001))
    cos_w0 = math.cos(w0)

    b0 = 1.0 + alpha * A
    b1 = -2.0 * cos_w0
    b2 = 1.0 - alpha * A
    a0 = 1.0 + alpha / A
    a1 = -2.0 * cos_w0
    a2 = 1.0 - alpha / A

    # Normalize by a0
    return {
        "b0": b0 / a0,
        "b1": b1 / a0,
        "b2": b2 / a0,
        "a0": 1.0,
        "a1": a1 / a0,
        "a2": a2 / a0,
    }


def calculate_biquad_response(coeffs: Dict[str, float], eval_freq_hz: float, sample_rate_hz: float = 48000.0) -> float:
    """Calculates magnitude response of biquad filter in decibels (dB) at eval_freq_hz."""
    w = 2.0 * math.pi * (eval_freq_hz / sample_rate_hz)
    z = cmath.exp(-1j * w)
    z2 = z * z

    num = coeffs["b0"] + coeffs["b1"] * z + coeffs["b2"] * z2
    den = 1.0 + coeffs["a1"] * z + coeffs["a2"] * z2

    h = num / den
    mag = abs(h)
    return 20.0 * math.log10(max(mag, 1e-12))


def check_biquad_stability(coeffs: Dict[str, float]) -> bool:
    """
    Checks if biquad filter poles lie strictly within the unit circle (|z| < 1.0).
    Denominator is z^2 + a1*z + a2 = 0.
    """
    a1 = coeffs["a1"]
    a2 = coeffs["a2"]
    disc = a1 * a1 - 4.0 * a2
    r1 = (-a1 + cmath.sqrt(disc)) / 2.0
    r2 = (-a1 - cmath.sqrt(disc)) / 2.0
    return abs(r1) < 1.0 and abs(r2) < 1.0


def calculate_crossfeed_delay_samples(delay_us: float = 270.0, sample_rate_hz: float = 44100.0) -> int:
    """Calculates integer sample delay for inter-aural time difference (ITD)."""
    delay_sec = delay_us * 1e-6
    return max(1, round(delay_sec * sample_rate_hz))


def simulate_bauer_crossfeed(
    left_samples: List[float],
    right_samples: List[float],
    sample_rate_hz: float = 44100.0,
    delay_us: float = 270.0,
    cross_gain_db: float = -4.5,
    bypass: bool = False,
) -> Tuple[List[float], List[float]]:
    """
    Simulates Bauer headphone stereophonic crossfeed blending.
    If bypass=True, returns bit-perfect copy of left and right input samples.
    """
    if bypass:
        return list(left_samples), list(right_samples)

    delay = calculate_crossfeed_delay_samples(delay_us, sample_rate_hz)
    cross_gain = 10.0 ** (cross_gain_db / 20.0)

    out_left = []
    out_right = []
    n = len(left_samples)

    for i in range(n):
        l_orig = left_samples[i]
        r_orig = right_samples[i]

        delayed_r = right_samples[i - delay] if (i - delay) >= 0 else 0.0
        delayed_l = left_samples[i - delay] if (i - delay) >= 0 else 0.0

        blended_l = (l_orig + delayed_r * cross_gain) / (1.0 + cross_gain)
        blended_r = (r_orig + delayed_l * cross_gain) / (1.0 + cross_gain)

        out_left.append(blended_l)
        out_right.append(blended_r)

    return out_left, out_right


def apply_replaygain_and_limiter(
    samples: List[float],
    gain_db: float,
    headroom_db: float = -0.5,
    bypass: bool = False,
) -> List[float]:
    """
    Applies ReplayGain linear scale and soft-clips peaks exceeding headroom threshold.
    If bypass=True, returns unmodified copy of input samples.
    """
    if bypass:
        return list(samples)

    total_gain_db = gain_db + headroom_db
    gain_linear = 10.0 ** (total_gain_db / 20.0)
    out = []

    for s in samples:
        scaled = s * gain_linear
        # Soft limiter above 0.95
        if scaled > 0.95:
            scaled = 0.95 + 0.05 * math.tanh((scaled - 0.95) / 0.05)
        elif scaled < -0.95:
            scaled = -0.95 + 0.05 * math.tanh((scaled + 0.95) / 0.05)
        out.append(scaled)

    return out


def db_to_linear(gain_db: float) -> float:
    """Converts decibels to linear amplitude ratio: 10^(gain_db / 20)."""
    return 10.0 ** (gain_db / 20.0)


def db_to_linear_gain(gain_db: float) -> float:
    """Alias for db_to_linear."""
    return db_to_linear(gain_db)


def select_gain(track_gain: float, album_gain: float, is_album_mode: bool) -> float:
    """Returns album gain in album listening mode, otherwise track gain."""
    return album_gain if is_album_mode else track_gain


def select_replaygain(track_gain_db: float, album_gain_db: float, is_album_mode: bool) -> float:
    """Alias for select_gain."""
    return select_gain(track_gain_db, album_gain_db, is_album_mode)


def validate_spsc_capacity(capacity: int) -> bool:
    """Verifies that ring buffer capacity is a non-zero power of two."""
    return capacity > 0 and (capacity & (capacity - 1)) == 0


def is_power_of_two(n: int) -> bool:
    """Alias for validate_spsc_capacity."""
    return validate_spsc_capacity(n)


def validate_buffer_size(frames: int) -> bool:
    """Verifies ASIO/WASAPI buffer size is power of two between 32 and 4096 frames."""
    if frames < 32 or frames > 4096:
        return False
    return (frames & (frames - 1)) == 0


class SPSCBuffer:
    """Lock-free single-producer single-consumer circular ring buffer reference model."""

    def __init__(self, capacity: int = 16):
        if not validate_spsc_capacity(capacity):
            raise ValueError(f"Capacity must be a power of two, got {capacity}")
        self.capacity: int = capacity
        self.mask: int = capacity - 1
        self.buf: List[float] = [0.0] * capacity
        self.write_idx: int = 0
        self.read_idx: int = 0
        self.underruns: int = 0
        self.overruns: int = 0

    def write(self, item_or_samples: Union[float, int, List[float]]) -> Union[bool, int]:
        """
        If item is a float/int, writes single sample and returns True, or False if buffer is full.
        If item is a list of floats, writes as many as will fit and returns count of samples written.
        """
        if isinstance(item_or_samples, (list, tuple)):
            written = 0
            for s in item_or_samples:
                if (self.write_idx - self.read_idx) >= self.capacity:
                    self.overruns += 1
                    break
                self.buf[self.write_idx & self.mask] = float(s)
                self.write_idx += 1
                written += 1
            return written
        else:
            if (self.write_idx - self.read_idx) >= self.capacity:
                self.overruns += 1
                return False
            self.buf[self.write_idx & self.mask] = float(item_or_samples)
            self.write_idx += 1
            return True

    def read(self, count: Optional[int] = None) -> Union[Optional[float], List[float]]:
        """
        If count is None, reads single item (returns None if empty).
        If count is integer, reads up to count samples (increments underruns if empty) and returns list.
        """
        if count is None:
            if self.read_idx == self.write_idx:
                return None
            item = self.buf[self.read_idx & self.mask]
            self.read_idx += 1
            return item
        else:
            out = []
            for _ in range(count):
                if self.read_idx == self.write_idx:
                    self.underruns += 1
                    break
                out.append(self.buf[self.read_idx & self.mask])
                self.read_idx += 1
            return out

    def available_read(self) -> int:
        return self.write_idx - self.read_idx

    def available_to_read(self) -> int:
        return self.available_read()

    def available_write(self) -> int:
        return self.capacity - self.available_read()

    def available_to_write(self) -> int:
        return self.available_write()

    def is_full(self) -> bool:
        return (self.write_idx - self.read_idx) >= self.capacity

    def is_empty(self) -> bool:
        return self.read_idx == self.write_idx


class ReferenceRingBuffer(SPSCBuffer):
    """ReferenceRingBuffer alias for SPSCBuffer."""
    pass


class SPSCAtomicRingBuffer(SPSCBuffer):
    """SPSCAtomicRingBuffer alias for SPSCBuffer."""
    pass


class DspPipelineController:
    """Controller for DSP pipeline bypass state."""

    def __init__(self, bypassed: bool = False):
        self.bypass: bool = bypassed

    def toggle_bypass(self) -> bool:
        self.bypass = not self.bypass
        return self.bypass

    def set_bypass(self, state: bool) -> None:
        self.bypass = state

    def is_bypassed(self) -> bool:
        return self.bypass


class DspPipeline(DspPipelineController):
    """Reference DSP pipeline with instant bypass processing."""

    def process(self, samples: List[float], bypass: Optional[bool] = None) -> List[float]:
        is_bp = self.bypass if bypass is None else bypass
        if is_bp:
            return list(samples)
        return [s * 1.5 for s in samples]


def process_dsp_chain(
    samples: List[float],
    biquad_coeffs: Optional[Dict[str, float]] = None,
    crossfeed_active: bool = False,
    dsp_bypass: bool = False,
) -> List[float]:
    """Applies DSP processing chain; returns bit-perfect copy if dsp_bypass is True."""
    if dsp_bypass or biquad_coeffs is None:
        return list(samples)
    out = []
    b0, b1, b2 = biquad_coeffs["b0"], biquad_coeffs["b1"], biquad_coeffs["b2"]
    a1, a2 = biquad_coeffs["a1"], biquad_coeffs["a2"]
    x1 = x2 = y1 = y2 = 0.0
    for x in samples:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        out.append(y)
        x2, x1 = x1, x
        y2, y1 = y1, y
    return out


def select_dsd_playback_strategy(
    dac_caps_or_format: Dict[str, Any],
    dac_backend: Optional[Dict[str, Any]] = None,
) -> str:
    """
    Evaluates DAC capabilities and audio format to select the priority playback path.
    - If called with (audio_format, dac_backend), returns 'native_dsd_direct' or 'pcm_downsample_88200'.
    - If called with (dac_caps), returns 'native_asio' -> 'dop' -> 'pcm_downsampling'.
    """
    if dac_backend is not None:
        if dac_caps_or_format.get("is_dsd") and dac_backend.get("supports_native_dsd"):
            return "native_dsd_direct"
        return "pcm_downsample_88200"
    else:
        if dac_caps_or_format.get("native_dsd"):
            return "native_asio"
        elif dac_caps_or_format.get("dop_support"):
            return "dop"
        return "pcm_downsampling"


def command_hardware_rate(dac_supported_rates: List[int], song_rate: int) -> bool:
    """Checks if DAC natively supports the requested sample rate."""
    return song_rate in dac_supported_rates


def is_hardware_rate_supported(supported_rates: List[int], song_rate: int) -> bool:
    """Alias for command_hardware_rate."""
    return command_hardware_rate(supported_rates, song_rate)


def select_backend(asio_avail: bool, wasapi_excl_avail: bool, wasapi_shared_avail: bool = True) -> str:
    """Resolves fallback output backend hierarchy: ASIO -> WASAPI Exclusive -> WASAPI Shared."""
    if asio_avail:
        return "windows_asio"
    elif wasapi_excl_avail:
        return "windows_wasapi_exclusive"
    return "windows_wasapi_shared"


def select_output_backend(asio_avail: bool, wasapi_excl_avail: bool, wasapi_shared_avail: bool = True) -> str:
    """Alias for select_backend."""
    return select_backend(asio_avail, wasapi_excl_avail, wasapi_shared_avail)


def select_hardware_backend(asio_avail: bool, wasapi_excl_avail: bool, wasapi_shared_avail: bool = True) -> str:
    """Alias for select_backend."""
    return select_backend(asio_avail, wasapi_excl_avail, wasapi_shared_avail)


def simulate_signal_path(
    source_label: str,
    bit_depth: int,
    sample_rate_hz: int,
    is_dsd: bool,
    dsp_bypass: bool,
    dsp_active: bool,
    resampled_to_hz: Optional[int],
    backend: str,
    device_name: str,
) -> Dict[str, Any]:
    """
    Simulates core-audio's build_signal_path() quality tier and node stages.
    Returns:
      {
        "overall": "lossless" | "enhanced" | "high_quality",
        "nodes": [ {"stage": str, "detail": str, "quality": str}, ... ]
      }
    """
    nodes = []
    overall = "lossless"

    dsd_str = " DSD" if is_dsd else ""
    src_desc = f"{source_label} ({bit_depth}-bit / {sample_rate_hz} Hz{dsd_str})"
    nodes.append({
        "stage": "Source",
        "detail": src_desc,
        "quality": "lossless",
    })

    if not dsp_bypass and dsp_active:
        overall = "enhanced"
        nodes.append({
            "stage": "64-bit DSP",
            "detail": "Active (PEQ / Crossfeed / Gain)",
            "quality": "enhanced",
        })

    if resampled_to_hz is not None:
        overall = "enhanced"
        nodes.append({
            "stage": "Sample Rate Conversion",
            "detail": f"{sample_rate_hz} Hz -> {resampled_to_hz} Hz (64-bit Sinc)",
            "quality": "enhanced",
        })

    lossless_backends = {"windows_asio", "windows_wasapi_exclusive", "macos_core_audio_hog"}
    if backend in lossless_backends:
        out_quality = "lossless"
    elif backend == "windows_wasapi_shared":
        overall = "high_quality"
        out_quality = "high_quality"
    else:
        out_quality = "enhanced"

    nodes.append({
        "stage": "Output",
        "detail": f"{device_name} ({backend})",
        "quality": out_quality,
    })

    return {
        "overall": overall,
        "nodes": nodes,
    }
