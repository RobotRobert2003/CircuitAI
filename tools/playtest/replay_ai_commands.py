"""Stream Recoil v5 replay AI commands without replaying the simulation.

Read-only diagnostic for retained .sdfz evidence. Packet layout comes from
Recoil BaseNetProtocol::SendAICommand, not the older NetMessageTypes comment.
Frames identify packet ordering in the replay, not the AI's decision frame:
network delivery can cross frame boundaries. Lua-issued orders are not present
as AI packets. Batched AICOMMANDS is counted but deliberately not decoded.
"""
import argparse
import collections
import gzip
import json
import struct
from pathlib import Path

HEADER = struct.Struct('<16sii256s16sQiiiiiiiiiiii')
CHUNK = struct.Struct('<fI')
AI_COMMAND = struct.Struct('<BBBhiiBI')


def exact_read(stream, count):
    data = stream.read(count)
    if len(data) != count:
        raise ValueError('Truncated replay')
    return data


def commands(path):
    """O(stream bytes), bounded packet memory; no whole replay decompression."""
    with gzip.open(path, 'rb') as stream:
        header = HEADER.unpack(exact_read(stream, HEADER.size))
        if header[0] != b'spring demofile\0' or header[1] != 5:
            raise ValueError('Expected a Recoil v5 replay')
        if header[2] < HEADER.size or header[6] < 0 or header[7] <= 0:
            raise ValueError('Missing or invalid finalized replay stream')
        stream.seek(header[2] + header[6])
        remaining = header[7]
        frame = 0
        while remaining:
            if remaining < CHUNK.size:
                raise ValueError('Incomplete replay chunk header')
            timestamp, size = CHUNK.unpack(exact_read(stream, CHUNK.size))
            remaining -= CHUNK.size
            if size < 1 or size > remaining:
                raise ValueError('Invalid replay packet size')
            packet = exact_read(stream, size)
            remaining -= size
            kind = packet[0]
            if kind == 1:
                frame = struct.unpack_from('<i', packet, 1)[0]
            elif kind == 2:
                frame += 1
            elif kind == 15:
                yield dict(frame=frame, packet_type=kind, undecoded=True)
            elif kind in (14, 76):
                if size < 3 + AI_COMMAND.size or struct.unpack_from('<H', packet, 1)[0] != size:
                    raise ValueError('Invalid AI command header')
                player, instance, team, unit, command, timeout, options, count = AI_COMMAND.unpack_from(packet, 3)
                offset = 3 + AI_COMMAND.size + (4 if kind == 76 else 0)
                if offset + count * 4 != size:
                    raise ValueError('Invalid AI command parameter count')
                parameters = struct.unpack_from('<' + 'f' * count, packet, offset)
                yield dict(frame=frame, seconds=timestamp, packet_type=kind,
                           player=player, instance=instance, team=team, unit=unit,
                           command=command, timeout=timeout, options=options,
                           parameters=parameters, bytes=size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('replay', type=Path)
    parser.add_argument('--unit', type=int)
    parser.add_argument('--from-frame', type=int, default=0)
    parser.add_argument('--to-frame', type=int, default=2**31-1)
    args = parser.parse_args()
    counts = collections.Counter()
    for record in commands(args.replay):
        counts[record['packet_type']] += 1
        if args.from_frame <= record['frame'] <= args.to_frame and (
            args.unit is None or record.get('unit') == args.unit):
            print(json.dumps(record))
    print(json.dumps(dict(packet_counts=counts, note='AI packets, not all engine UnitCommand events')))


if __name__ == '__main__':
    main()
