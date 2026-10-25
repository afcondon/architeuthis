# Selene: a Live 11 control surface that binds Selene's MIDI signals to
# parameters in Live by name (docs/kb/plans/selene-ableton-destinations.md).
#
# Choose it in Live's Preferences > Link/Tempo/MIDI as a Control Surface,
# with Input "IAC Driver (Tidal)" and Output None. `make ableton` in
# Architeuthis installs it into the User Library.
#
# The rig's rack is the truth and this script keeps nothing of its own.
# Every second Architeuthis (selene_ableton) sends it, over UDP on
# 127.0.0.1:57140, the signals that have a destination:
#
#   bindings [{"key": "midi1 1", "channel": 1, "cc": 20, "to": "Bass/Auto Filter/Frequency"}, ...]
#
# It binds each by name in the Set that is open, with Live's own MIDI map
# (an EncoderElement connected to the parameter, as Live's bundled scripts
# do), and answers with how each went and whether its parameter moved since
# the last report, which is how the rig tells a binding a hand mapping has
# taken over:
#
#   report [{"key": "midi1 1", "state": "bound" | "unbound" | "ambiguous", "said": "...", "moved": true}, ...]
#
# `selected` answers with the parameter last clicked in Live, and how many
# parameters in the Set have its name: selected {"path": "...", "count": 1}
# (path null when nothing is).
#
# A name is Live's own: the track, then each device (and a rack's chains),
# then the parameter, joined by "/". A name is never guessed: one the Set
# lacks is unbound, and one it has twice is ambiguous.

import json
import socket
import time

import Live
from _Framework.ControlSurface import ControlSurface
from _Framework.EncoderElement import EncoderElement
from _Framework.InputControlElement import MIDI_CC_TYPE

PORT = 57140
# How often names already found are looked up again when the bindings are
# the same, to pick up a track renamed away or a device replaced.
RESOLVE_EVERY = 5.0


def name_of(obj):
    if isinstance(obj, Live.MixerDevice.MixerDevice):
        return 'Mixer'
    return getattr(obj, 'name', type(obj).__name__)


def path_of(param):
    names = [param.name]
    parent = param.canonical_parent
    while parent is not None and not isinstance(parent, Live.Song.Song):
        names.append(name_of(parent))
        parent = getattr(parent, 'canonical_parent', None)
    return '/'.join(reversed(names))


def mixer_params(mixer):
    params = []
    for attr in ('volume', 'panning'):
        p = getattr(mixer, attr, None)
        if p is not None:
            params.append(p)
    params.extend(getattr(mixer, 'sends', []))
    return params


def device_params(device):
    params = list(device.parameters)
    if getattr(device, 'can_have_chains', False):
        for chain in device.chains:
            params.extend(mixer_params(chain.mixer_device))
            for d in chain.devices:
                params.extend(device_params(d))
    return params


def params_by_path(song):
    tracks = list(song.tracks) + list(song.return_tracks) + [song.master_track]
    index = {}
    for track in tracks:
        params = mixer_params(track.mixer_device)
        for d in track.devices:
            params.extend(device_params(d))
        for p in params:
            index.setdefault(path_of(p), []).append(p)
    return index


def alive(param):
    try:
        param.name
        return True
    except Exception:
        return False


class Selene(ControlSurface):

    def __init__(self, c_instance):
        ControlSurface.__init__(self, c_instance)
        # one encoder per channel and CC ever used, kept: an encoder can be
        # released, but not taken out of the surface
        self._encoders = {}
        # key -> {channel, cc, to, param, state, said, last}
        self._bound = {}
        self._wanted = None
        self._resolved_at = 0.0
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(('127.0.0.1', PORT))
        self._sock.setblocking(False)
        self.log_message('Selene: listening on %d' % PORT)

    # -- binding -----------------------------------------------------------

    def _encoder(self, channel, cc):
        key = (channel, cc)
        if key not in self._encoders:
            with self.component_guard():
                encoder = EncoderElement(MIDI_CC_TYPE, channel - 1, cc, Live.MidiMap.MapMode.absolute)
                # a signal never rests for takeover to pick up from
                encoder.set_needs_takeover(False)
            self._encoders[key] = encoder
        return self._encoders[key]

    def _resolve(self, wanted):
        index = params_by_path(self.song())
        bound = {}
        for w in wanted:
            key, to = w['key'], w['to']
            was = self._bound.get(key)
            found = index.get(to, [])
            entry = {'channel': w['channel'], 'cc': w['cc'], 'to': to, 'param': None,
                     'last': was['last'] if was else None}
            if len(found) == 1:
                entry.update(state='bound', said='', param=found[0])
            elif not found:
                entry.update(state='unbound', said='no %s in this Set' % to)
            else:
                entry.update(state='ambiguous', said='%d parameters in this Set are called %s' % (len(found), to))
            bound[key] = entry
        # each encoder to its parameter, or released; the MIDI map rebuilt
        # only when something changed
        targets = {}
        for entry in bound.values():
            if entry['param'] is not None:
                targets[(entry['channel'], entry['cc'])] = entry
        changed = False
        for ch_cc, entry in targets.items():
            encoder = self._encoder(*ch_cc)
            held = self._holding(ch_cc)
            if held is None or held['to'] != entry['to'] or not alive(held['param']):
                with self.component_guard():
                    encoder.connect_to(entry['param'])
                changed = True
                self.log_message('Selene: ch%d cc%d -> %s' % (ch_cc[0], ch_cc[1], entry['to']))
            else:
                entry['param'] = held['param']
        for ch_cc, encoder in self._encoders.items():
            if ch_cc not in targets and self._holding(ch_cc) is not None:
                with self.component_guard():
                    encoder.release_parameter()
                changed = True
                self.log_message('Selene: ch%d cc%d released' % ch_cc)
        self._bound = bound
        self._wanted = wanted
        self._resolved_at = time.time()
        if changed:
            self.request_rebuild_midi_map()

    def _holding(self, ch_cc):
        for entry in self._bound.values():
            if entry['param'] is not None and (entry['channel'], entry['cc']) == ch_cc:
                return entry
        return None

    def _report(self):
        out = []
        for key, entry in self._bound.items():
            moved = False
            if entry['param'] is not None:
                try:
                    value = entry['param'].value
                    moved = entry['last'] is not None and value != entry['last']
                    entry['last'] = value
                except Exception:
                    pass
            out.append({'key': key, 'state': entry['state'], 'said': entry['said'], 'moved': moved})
        return 'report ' + json.dumps(out)

    def _selected(self):
        param = self.song().view.selected_parameter
        if param is None:
            return 'selected ' + json.dumps({'path': None, 'count': 0})
        path = path_of(param)
        count = len(params_by_path(self.song()).get(path, []))
        return 'selected ' + json.dumps({'path': path, 'count': count})

    # -- words -------------------------------------------------------------

    def _answer(self, data):
        if data.startswith('bindings '):
            wanted = json.loads(data[len('bindings '):])
            stale = any(e['param'] is not None and not alive(e['param']) for e in self._bound.values())
            # a name not found is looked for every time, so fixing it in Live
            # shows at once; one found, every RESOLVE_EVERY
            missing = any(e['param'] is None for e in self._bound.values())
            if wanted != self._wanted or stale or missing or time.time() - self._resolved_at > RESOLVE_EVERY:
                self._resolve(wanted)
            return self._report()
        if data.strip() == 'selected':
            return self._selected()
        return None

    def update_display(self):
        ControlSurface.update_display(self)
        while True:
            try:
                data, sender = self._sock.recvfrom(65536)
            except (BlockingIOError, socket.error):
                return
            try:
                reply = self._answer(data.decode('utf-8'))
            except Exception as e:
                self.log_message('Selene: %s' % e)
                reply = None
            if reply is not None:
                try:
                    self._sock.sendto(reply.encode('utf-8'), sender)
                except Exception:
                    pass

    def disconnect(self):
        for encoder in self._encoders.values():
            try:
                encoder.release_parameter()
            except Exception:
                pass
        try:
            self._sock.close()
        except Exception:
            pass
        ControlSurface.disconnect(self)


def create_instance(c_instance):
    return Selene(c_instance)
