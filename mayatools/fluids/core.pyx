import ast
import copy
import os
import re
import xml.etree.cElementTree as etree

from .. import binary


class Cache(object):

    _interesting_extra = set((
        'dimensionsW', 'dimensionsH', 'dimensionsD',
        'resolutionW', 'resolutionH', 'resolutionD',
    ))

    def __init__(self, xml_path=None):

        self.xml_path = self.directory = self.base_name = None

        if xml_path:
            self.set_path(xml_path)
            self.etree = etree.parse(self.xml_path)
            self.parse_xml()

        self._frames = []

    def free(self):
        for frame in self._frames:
            frame.free()

    def clone(self):
        clone = self.__class__()
        clone.etree = copy.deepcopy(self.etree)
        clone.parse_xml()
        return clone

    def set_path(self, xml_path):
        self.xml_path = os.path.abspath(xml_path)
        self.directory = os.path.dirname(self.xml_path)
        self.base_name = os.path.splitext(os.path.basename(self.xml_path))[0]

    def parse_xml(self):

        self.time_per_frame = int(self.etree.find('cacheTimePerFrame').get('TimePerFrame'))
        assert self.time_per_frame == 250, 'Non-standard TimePerFrame'

        self.cache_type = self.etree.find('cacheType').get('Type')
        assert self.cache_type == 'OneFilePerFrame', 'Not OneFilePerFrame'

        self.cache_format = self.etree.find('cacheType').get('Format')
        assert self.cache_format == 'mcc', 'Not "mcc"'

        # Parse all the extra info. We will extract resolution and dimensions
        # from this.
        self.extra = {}
        for element in self.etree.findall('extra'):
            m = re.match(r'^([^\.]+)\.(\w+)=(.+?)$', element.text)
            if not m:
                continue
            name, key, raw_value = m.groups()
            if key not in self._interesting_extra:
                continue
            try:
                value = ast.literal_eval(raw_value)
            except (ValueError, SyntaxError):
                value = raw_value
            self.extra.setdefault(name, {})[key] = value

        self.shape_specs = {}
        for name, data in sorted(self.extra.iteritems()):
            self.shape_specs[name] = ShapeSpec(name, **data)

        self.channel_specs = {}
        for channel_element in self.etree.find('Channels'):
            channel_spec = ChannelSpec.from_xml_attrib(channel_element.attrib)
            self.channel_specs[channel_spec.name] = channel_spec

    def pprint(self):
        print self.xml_path
        print '\ttimePerFrame:', self.time_per_frame
        print '\tcacheType:', self.cache_type
        print '\tcacheFormat:', self.cache_format
        print '\traw "extra" data:'
        for name, extra in sorted(self.extra.iteritems()):
            for k, v in sorted(extra.iteritems()):
                print '\t\t%s.%s: %r' % (name, k, v)
        print '\tshape specifications:'
        for name, shape_spec in sorted(self.shape_specs.iteritems()):
            print '\t\t%s:' % name
            print '\t\t\tdimensions:', shape_spec.dimensions
            print '\t\t\tresolution:', shape_spec.resolution
            print '\t\t\tunit_size:', shape_spec.unit_size
        print '\tchannel specifications:'
        for channel_name, channel_spec in sorted(self.channel_specs.iteritems()):
            print '\t\t%s' % (channel_name, )

    @property
    def frames(self):
        if not self._frames:

            name_re = re.compile(r'^%sFrame(\d+)(?:Tick(\d))?\.mc$' % re.escape(self.base_name))
            for file_name in os.listdir(self.directory):
                m = name_re.match(file_name)
                if m:
                    frame = Frame(self, os.path.join(self.directory, file_name))
                    self._frames.append(frame)

        return self._frames

    def update_xml(self):

        min_time = min(f.start_time for f in self.frames)
        max_time = max(f.end_time for f in self.frames)
        self.etree.find('time').set('Range', '%d-%d' % (min_time, max_time))
        for channel in self.etree.find('Channels'):
            channel.set('SamplingType', 'Irregular')
            channel.set('StartTime', str(min_time))
            channel.set('EndTime', str(max_time))

    def write_xml(self, path):
        self.etree.write(path)


class ShapeSpec(object):

    def __init__(self, name, **kwargs):
        self.name = name
        self.dimensions = tuple(kwargs.pop('dimensions' + axis) for axis in 'WHD')
        self.resolution = tuple(kwargs.pop('resolution' + axis) for axis in 'WHD')
        self.unit_size = tuple(float(d) / float(r) for d, r in zip(self.dimensions, self.resolution))

    def __repr__(self):
        return '<%s unit_size=%r>' % (self.__class__.__name__, self.unit_size)


class ChannelSpec(object):

    @classmethod
    def from_xml_attrib(cls, attrib):
        return cls(
            attrib['ChannelName'],
            attrib['ChannelInterpretation']
        )

    def __init__(self, name, interpretation=None):
        self.name = name
        self.shape, self.interpretation = self.name.rsplit('_', 1)
        if interpretation:
            assert self.interpretation == interpretation


class Frame(object):

    _header_tags = set(('STIM', 'ETIM'))

    def __init__(self, cache=None, path=None):

        self.cache = cache
        self.path = path
        self.parser = None

        self._channels = {}
        self._headers = {}
        self._shapes = {}

    def free(self):
        self.parser = None
        for channel in self._channels.itervalues():
            channel.data = ()
        self._channels = {}
        self._shapes = {}

    def pprint(self):
        print 'Frame from %d to %d' % (self.start_time, self.end_time)
        print 'Shapes:'
        for shape_name, shape in sorted(self.shapes.iteritems()):
            print '\t%s:' % shape_name
            print '\t\tresolution: %r' % (shape.resolution, )
            print '\t\toffset: %r' % (shape.offset, )
            print '\t\tbb_min: %r' % (shape.bb_min, )
            print '\t\tbb_max: %r' % (shape.bb_max, )

    def parse_headers(self):
        self.parser = self.parser or binary.Parser(open(self.path, 'rb'))
        while True:
            if all(tag in self._headers for tag in self._header_tags):
                break
            chunk = self.parser.parse_next()
            if chunk.tag in self._header_tags:
                self._headers[chunk.tag] = chunk.ints[0]

    @property
    def headers(self):
        if not self._headers and self.path:
            self.parse_headers()
        return self._headers

    @property
    def start_time(self):
        return self.headers.get('STIM')
    @property
    def end_time(self):
        return self.headers.get('ETIM')

    def set_times(self, start, end):
        self.headers['STIM'] = int(start)
        self.headers['ETIM'] = int(end)

    @property
    def channels(self):
        if not self._channels and self.path:
            self.shapes
        return self._channels

    @property
    def shapes(self):
        if not self._shapes and self.path:

            for shape_name, shape_spec in self.cache.shape_specs.iteritems():
                shape = Shape(self, shape_spec)
                self._shapes[shape_name] = shape

            self.parse_headers()
            self.parser.parse_all()
            channels = self.parser.find_one('MYCH')
            for name, data in zip(channels.find('CHNM'), channels.find('FBCA')):
                name = name.string
                data = data.floats
                self._channels[name] = Channel(self, name, data)

            for shape in self._shapes.itervalues():
                shape.finalize()

        return self._shapes

    def dumps_iter(self):
        """Prepare all channels and specs for dumping, and then do it."""

        root = binary.Node()

        header = root.add_group('CACH')
        header.add_chunk('VRSN').string = '0.1'
        header.add_chunk('STIM').ints = [self.headers['STIM']]
        header.add_chunk('ETIM').ints = [self.headers['ETIM']]

        channels = root.add_group('MYCH')
        for interpretation, channel in self.channels.iteritems():
            channels.add_chunk('CHNM').string = channel.name
            channels.add_chunk('SIZE').ints = [len(channel.data)]
            channels.add_chunk('FBCA').floats = channel.data
            print channel.name, len(channel.data)

        return root.dumps_iter()

cdef class Shape(object):
    
    cdef public object frame, cache, spec, channels
    cdef public object resolution, offset
    cdef public object bb_min, bb_max
    cdef public object src_a, src_b

    def __init__(self, frame, spec, channels=None):

        self.frame = frame
        self.cache = frame.cache
        self.spec = spec
        self.channels = dict(channels or {})

    def finalize(self):

        res_channel = self.channels.get('resolution')
        if res_channel:
            self.resolution = res_channel.data
        else:
            self.resolution = self.spec.resolution

        off_channel = self.channels.get('offset')
        if off_channel:
            self.offset = off_channel.data
        else:
            self.offset = self.spec.offset

        self.bb_min = tuple(o - r * u / 2.0 for o, r, u in zip(self.offset, self.resolution, self.spec.unit_size))
        self.bb_max = tuple(o + r * u / 2.0 for o, r, u in zip(self.offset, self.resolution, self.spec.unit_size))

    def iter_centers(self):
        cdef int xi, yi, zi
        cdef float x, y, z
        for zi in xrange(self.resolution[2]):
            z = self.bb_min[2] + self.spec.unit_size[2] * (0.5 + zi)
            for yi in xrange(self.resolution[1]):
                y = self.bb_min[1] + self.spec.unit_size[1] * (0.5 + yi)
                for xi in xrange(self.resolution[0]):
                    x = self.bb_min[0] + self.spec.unit_size[0] * (0.5 + xi)
                    yield x, y, z

    cpdef index_for_point(self, float x, float y, float z):

        if x < self.bb_min[0] or x > self.bb_max[0]:
            raise IndexError('x')
        if y < self.bb_min[1] or y > self.bb_max[1]:
            raise IndexError('y')
        if z < self.bb_min[2] or z > self.bb_max[2]:
            raise IndexError('z')

        xi = int((x - self.bb_min[0]) / self.spec.unit_size[0])
        yi = int((y - self.bb_min[1]) / self.spec.unit_size[1])
        zi = int((z - self.bb_min[2]) / self.spec.unit_size[2])
        return xi, yi, zi

    cpdef float lookup_value(self, channel, float x, float y, float z):
        
        try:
            xi, yi, zi = self.index_for_point(x, y, z)
        except IndexError:
            return (0.0, ) * channel.data_size

        xr = int(self.resolution[0])
        yr = int(self.resolution[1])
        index = channel.data_size * (xi + (yi * xr) + (zi * xr * yr))
        return channel.data[index:index + channel.data_size]

    @classmethod
    def setup_blend(cls, frame, name, shape_a, shape_b):

        self = cls(frame, frame.cache.shape_specs[name])
        frame._shapes[name] = self


        if isinstance(shape_a, Frame):
            shape_a = shape_a.shapes[name]
        if isinstance(shape_b, Frame):
            shape_b = shape_b.shapes[name]

        self.src_a = shape_a
        self.src_b = shape_b

        self.bb_min = tuple(min(a, b) for a, b in zip(shape_a.bb_min, shape_b.bb_min))
        self.bb_max = tuple(max(a, b) for a, b in zip(shape_a.bb_max, shape_b.bb_max))
        self.resolution = tuple(int(round((b - a) / shape_a.spec.unit_size[i])) for i, (a, b) in enumerate(zip(self.bb_min, self.bb_max)))
        self.offset = tuple((a + b) / 2.0 for a, b in zip(self.bb_min, self.bb_max))

        # Create basic channels.
        self.channels['resolution'] = Channel(self.frame, name + '_resolution', self.resolution)
        self.channels['offset'] = Channel(self.frame, name + '_offset', self.offset)

        return self

    def blend(self, blend_factor):

        blend_factor_inv = 1.0 - blend_factor

        shape_a = self.src_a
        lookup_a = shape_a.lookup_value
        shape_b = self.src_b
        lookup_b = shape_b.lookup_value

        for interpretation, a_channel in sorted(shape_a.channels.iteritems()):

            if not a_channel.data_size:
                continue

            b_channel = shape_b.channels[interpretation]

            data = []
            dst_channel = Channel(self.frame, self.spec.name + '_' + interpretation, data)
            self.channels[interpretation] = dst_channel

            print '\t\tblend', interpretation
            for centre in self.iter_centers():
                index = self.index_for_point(*centre)
                a = lookup_a(a_channel, *centre)
                b = lookup_b(b_channel, *centre)
                data.extend(av * blend_factor_inv + bv * blend_factor for av, bv in zip(a, b))


class Channel(object):

    def __init__(self, frame, name, data):

        self.frame = frame
        self.cache = frame.cache

        self.name = name
        self.spec = self.cache.channel_specs[name]

        self.shape = self.frame._shapes[self.spec.shape]
        self.shape.channels[self.spec.interpretation] = self
        self.frame.channels[name] = self
        
        self.interpretation = self.spec.interpretation
        self.data_size = {
            'density': 1,
            'velocity': 3,
        }.get(self.interpretation, 0)

        self.data = data


if __name__ == '__main__':

    import sys
    cache = Cache(sys.argv[1])
    cache.pprint()
