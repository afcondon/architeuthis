# purerl-tidal Quick Start

## Running

```bash
cd /Users/afc/work/afc-work/PSD3-Repos/purerl-tidal

# Build and run
ERL_LIBS="_build/default/lib" spago run
```

## Connecting

Open browser console:

```javascript
ws = new WebSocket('ws://localhost:8080/ws')
ws.onmessage = e => console.log(e.data)
```

## Pattern Syntax

### Basic

```javascript
ws.send('bd')           // single kick
ws.send('bd sn hh cp')  // sequence: kick, snare, hat, clap
ws.send('~')            // silence
```

### Grouping

```javascript
ws.send('[bd sn]')      // both in first half of cycle
ws.send('[bd sn] hh')   // [bd sn] takes half, hh takes half
ws.send('[[bd bd] sn] hh cp')  // nested groups
```

### Repetition

```javascript
ws.send('bd*4')         // kick 4 times per cycle
ws.send('bd*2 sn')      // kick twice, then snare once
ws.send('hh*8')         // hi-hat eighth notes
```

### Slow Down

```javascript
ws.send('bd/2')         // kick every 2 cycles
ws.send('[bd sn hh cp]/2')  // pattern spans 2 cycles
```

### Euclidean Rhythms

```javascript
ws.send('bd(3,8)')      // 3 hits spread over 8 steps
ws.send('bd(5,8)')      // 5 hits spread over 8 steps
ws.send('hh(7,16)')     // 7 hits spread over 16 steps
ws.send('sn(2,5)')      // 2 hits spread over 5 steps
```

### Alternating

```javascript
ws.send('<bd sn>')      // alternates: bd on cycle 1, sn on cycle 2
ws.send('<bd sn cp>')   // cycles through all three
```

### Combined

```javascript
ws.send('bd*4 sn*2 hh*8')           // layered rhythms
ws.send('[bd sn] hh*4 cp/2')        // mixed operations
ws.send('bd(3,8) sn(2,5)')          // multiple euclidean
ws.send('<bd*2 bd(3,8)> sn')        // alternating with other
```

## Available Sounds

| Name | MIDI Note | GM Drum |
|------|-----------|---------|
| bd, kick | 36 | Bass Drum 1 |
| sn, snare | 38 | Acoustic Snare |
| hh, hihat | 42 | Closed Hi-Hat |
| ho, oh | 46 | Open Hi-Hat |
| cp, clap | 39 | Hand Clap |
| rim | 37 | Side Stick |
| lt, tom | 45 | Low Tom |
| mt | 47 | Mid Tom |
| ht | 50 | High Tom |
| cy, crash | 49 | Crash Cymbal |
| rd, ride | 51 | Ride Cymbal |
| cb | 56 | Cowbell |
| ~ | - | Silence |

## Ableton Setup

1. Open Audio MIDI Setup (macOS)
2. Enable IAC Driver
3. Create bus named "Tidal"
4. In Ableton: Preferences → MIDI → Enable "IAC Driver Tidal" as input
5. Create MIDI track with Drum Rack
6. Set input to "IAC Driver Tidal", channel 10
7. Arm track for recording

## Troubleshooting

### No sound
- Check MIDI routing in Ableton
- Ensure track is armed and monitoring
- Check channel 10 is receiving

### Wrong tempo
- Server runs at 120 BPM by default
- Set Ableton to 120 BPM for sync

### Connection refused
- Check server is running: `lsof -i :8080`
- Restart: `pkill -f beam && ERL_LIBS="_build/default/lib" spago run`

### Parse error
- Check syntax - brackets must match
- Use spaces between elements
- Numbers in euclidean: `bd(3,8)` not `bd(3, 8)`
