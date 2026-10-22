"""Known-wire replay examples; no game or retained archive required."""
import gzip
import struct
import tempfile
import unittest
from pathlib import Path
from replay_ai_commands import HEADER, AI_COMMAND, CHUNK, commands


class ReplayCommandsTest(unittest.TestCase):
    def write_replay(self, path, packets):
        stream = b''.join(CHUNK.pack(1., len(packet)) + packet for packet in packets)
        fields = [b'spring demofile\0', 5, HEADER.size, b'engine', bytes(16), 0,
                  0, len(stream), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        with gzip.open(path, 'wb') as output:
            output.write(HEADER.pack(*fields) + stream)

    def test_tracked_and_untracked_use_current_engine_field_order(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.sdfz'
            body = AI_COMMAND.pack(0, 3, 6, 26209, 10, 3000, 32, 3)
            packets = [b'\1' + struct.pack('<i', 90), b'\2']
            for kind in (14, 76):
                payload = body + (struct.pack('<i', 123) if kind == 76 else b'') + struct.pack('<3f', 64., -10., 128.)
                packets.append(bytes([kind]) + struct.pack('<H', len(payload)+3) + payload)
            self.write_replay(path, packets)
            result = list(commands(path))
            self.assertEqual(len(result), 2)
            for row in result:
                self.assertEqual((row['frame'], row['team'], row['unit']), (91, 6, 26209))
                self.assertEqual(row['parameters'], (64., -10., 128.))
                self.assertEqual((row['command'], row['options'], row['timeout']), (10, 32, 3000))

    def test_rejects_malformed_parameter_length(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.sdfz'
            payload = AI_COMMAND.pack(0, 0, 0, 1, 10, 30, 0, 3)
            self.write_replay(path, [bytes([14])+struct.pack('<H',len(payload)+3)+payload])
            with self.assertRaisesRegex(ValueError, 'parameter count'):
                list(commands(path))

    def test_marks_batch_packets_as_undecoded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.sdfz'
            self.write_replay(path, [bytes([15,3,0])])
            self.assertTrue(list(commands(path))[0]['undecoded'])


if __name__ == '__main__':
    unittest.main()
