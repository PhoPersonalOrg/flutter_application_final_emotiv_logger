#!/usr/bin/env python3
"""
Network receiver for Emotiv EEG/Motion data with optional LSL rebroadcast.

Receives UDP/TCP data from Flutter app and optionally rebroadcasts to LSL outlets.
This enables compatibility with LSL-based analysis tools when using the network stream.

Usage:
    python test_reciever.py [--lsl] [--port PORT] [--host HOST]

Options:
    --lsl          Enable LSL rebroadcast (requires pylsl)
    --port PORT    UDP port to listen on (default: 9878)
    --host HOST    Host address to bind to (default: 0.0.0.0)
"""

import json
import socket
import argparse
import sys
from typing import Optional

# Optional LSL support
try:
    import pylsl
    from pylsl import StreamInfo, StreamOutlet
    LSL_AVAILABLE = True
except ImportError:
    LSL_AVAILABLE = False
    print("Warning: pylsl not available. LSL rebroadcast disabled.")
    print("Install with: pip install pylsl")


class LSLRebroadcaster:
    """Manages LSL outlets for rebroadcasting network stream data."""

    def __init__(self):
        self.eeg_outlet: Optional[StreamOutlet] = None
        self.motion_outlet: Optional[StreamOutlet] = None
        self._initialized = False

    def initialize(self):
        """Create LSL outlets for EEG and motion streams."""
        if not LSL_AVAILABLE:
            raise RuntimeError("pylsl not available. Cannot create LSL outlets.")

        # EEG stream: 14 channels @ 128 Hz
        eeg_channel_names = [
            'AF3', 'F7', 'F3', 'FC5', 'T7', 'P7', 'O1',
            'O2', 'P8', 'T8', 'FC6', 'F4', 'F8', 'AF4'
        ]
        eeg_info = StreamInfo(
            name='Epoc X',
            type='EEG',
            channel_count=14,
            nominal_srate=128.0,
            channel_format=pylsl.cf_float32,
            source_id='network_receiver_eeg'
        )
        # Add channel labels
        chns = eeg_info.desc().append_child("channels")
        for label in eeg_channel_names:
            ch = chns.append_child("channel")
            ch.append_child_value("label", label)
            ch.append_child_value("unit", "µV")
            ch.append_child_value("type", "EEG")
        self.eeg_outlet = StreamOutlet(eeg_info)
        print("✓ Created LSL outlet: Epoc X (EEG, 14 channels @ 128 Hz)")

        # Motion stream: 6 channels @ 16 Hz
        motion_channel_names = ['AccX', 'AccY', 'AccZ', 'GyroX', 'GyroY', 'GyroZ']
        motion_info = StreamInfo(
            name='Epoc X Motion',
            type='SIGNAL',
            channel_count=6,
            nominal_srate=16.0,
            channel_format=pylsl.cf_float32,
            source_id='network_receiver_motion'
        )
        # Add channel labels
        chns = motion_info.desc().append_child("channels")
        for i, label in enumerate(motion_channel_names[:3]):
            ch = chns.append_child("channel")
            ch.append_child_value("label", label)
            ch.append_child_value("unit", "g")
            ch.append_child_value("type", "ACC")
        for i, label in enumerate(motion_channel_names[3:]):
            ch = chns.append_child("channel")
            ch.append_child_value("label", label)
            ch.append_child_value("unit", "deg/s")
            ch.append_child_value("type", "GYRO")
        self.motion_outlet = StreamOutlet(motion_info)
        print("✓ Created LSL outlet: Epoc X Motion (SIGNAL, 6 channels @ 16 Hz)")

        self._initialized = True
        print("LSL rebroadcast enabled. Streams available for LSL clients.")

    def push_sample(self, stream_type: str, values: list, timestamp: float):
        """Push a sample to the appropriate LSL outlet."""
        if not self._initialized:
            return

        # Convert timestamp: Flutter sends seconds since epoch, LSL uses local_clock()
        # We'll use LSL's local_clock() for relative timing, but preserve original timestamp
        lsl_timestamp = pylsl.local_clock()

        try:
            if stream_type == 'eeg' and self.eeg_outlet:
                if len(values) == 14:
                    self.eeg_outlet.push_sample(values, lsl_timestamp)
                else:
                    print(f"Warning: EEG sample has {len(values)} channels, expected 14")
            elif stream_type == 'motion' and self.motion_outlet:
                if len(values) == 6:
                    self.motion_outlet.push_sample(values, lsl_timestamp)
                else:
                    print(f"Warning: Motion sample has {len(values)} channels, expected 6")
            else:
                print(f"Warning: Unknown stream type '{stream_type}' or outlet not initialized")
        except Exception as e:
            print(f"Error pushing sample to LSL: {e}")

    def close(self):
        """Clean up LSL outlets."""
        if self.eeg_outlet:
            self.eeg_outlet = None
        if self.motion_outlet:
            self.motion_outlet = None
        self._initialized = False


def main():
    parser = argparse.ArgumentParser(
        description='Receive Emotiv data from network stream with optional LSL rebroadcast'
    )
    parser.add_argument(
        '--lsl',
        action='store_true',
        help='Enable LSL rebroadcast (requires pylsl)'
    )
    parser.add_argument(
        '--port',
        type=int,
        default=9878,
        help='UDP port to listen on (default: 9878)'
    )
    parser.add_argument(
        '--host',
        type=str,
        default='0.0.0.0',
        help='Host address to bind to (default: 0.0.0.0)'
    )
    args = parser.parse_args()

    # Initialize LSL rebroadcaster if requested
    rebroadcaster = None
    if args.lsl:
        if not LSL_AVAILABLE:
            print("Error: --lsl flag specified but pylsl is not available.")
            print("Install with: pip install pylsl")
            sys.exit(1)
        rebroadcaster = LSLRebroadcaster()
        try:
            rebroadcaster.initialize()
        except Exception as e:
            print(f"Error initializing LSL rebroadcast: {e}")
            sys.exit(1)

    # Create UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.host, args.port))
        print(f"Listening on {args.host}:{args.port}")
        if rebroadcaster:
            print("LSL rebroadcast: ENABLED")
        else:
            print("LSL rebroadcast: DISABLED (use --lsl to enable)")
        print("Press Ctrl+C to stop\n")

        sample_count = {'eeg': 0, 'motion': 0}

        while True:
            data, addr = sock.recvfrom(65535)
            for line in data.splitlines():
                try:
                    sample = json.loads(line)
                    stream_type = sample.get('type', 'unknown')
                    timestamp = sample.get('timestamp', 0.0)
                    values = sample.get('values', [])

                    # Print sample info
                    print(f"[{stream_type.upper()}] t={timestamp:.3f} "
                          f"channels={len(values)} values={values[:3]}...")

                    # Forward to LSL if enabled
                    if rebroadcaster:
                        rebroadcaster.push_sample(stream_type, values, timestamp)
                        sample_count[stream_type] = sample_count.get(stream_type, 0) + 1

                except json.JSONDecodeError as e:
                    print(f"Error parsing JSON: {e}")
                except Exception as e:
                    print(f"Error processing sample: {e}")

    except KeyboardInterrupt:
        print("\n\nStopping receiver...")
        if rebroadcaster:
            rebroadcaster.close()
            print("LSL outlets closed.")
        print("Receiver stopped.")
    except Exception as e:
        print(f"Error: {e}")
        if rebroadcaster:
            rebroadcaster.close()
        sys.exit(1)
    finally:
        sock.close()


if __name__ == "__main__":
    main()
