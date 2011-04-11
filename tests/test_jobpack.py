from random import random

from disco.json import loads
from disco.job import JobPack
from disco.test import TestCase

def random_bytes(size):
    return ''.join(chr(int(random() * 255)) for x in xrange(size))

hdr_size = JobPack.HEADER_SIZE
class JobPackTestCase(TestCase):
    def test_badmagic(self):
        offsets = [hdr_size, hdr_size + 1, hdr_size + 2, hdr_size + 3]
        jobpack = JobPack.header(offsets, magic=0) + '0'*4
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

    def test_badheader(self):
        offsets = [hdr_size + 1, hdr_size + 2, hdr_size + 2, hdr_size + 2]
        jobpack = JobPack.header(offsets) + '0'*3
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

        offsets = [hdr_size, hdr_size, hdr_size + 1, hdr_size + 1]
        jobpack = JobPack.header(offsets) + '0'*2
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

        offsets = [hdr_size, hdr_size+1, hdr_size, hdr_size + 1]
        jobpack = JobPack.header(offsets) + '0'*2
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

        offsets = [hdr_size, hdr_size+1, hdr_size+1, hdr_size]
        jobpack = JobPack.header(offsets) + '0'*2
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

    def test_baddict(self):
        offsets = [hdr_size, hdr_size+1, hdr_size+1, hdr_size+1]
        jobpack = JobPack.header(offsets) + '0'*2
        status, response = loads(self.disco.request('/disco/job/new', jobpack))
        self.assertEquals(status, 'error')

class JobPackInfoTestCase(TestCase):
    def test_badinfo(self):
        jobenvs, jobzip, jobdata = {}, '', ''
        jobdict = {}
        jobpack = JobPack(jobdict, jobenvs, jobzip, jobdata)
        status, response = loads(self.disco.request('/disco/job/new', jobpack.dumps()))
        self.assertEquals(status, 'error')
        self.assertGreater(response.find("missing key"), 0)

    def test_badprefix(self):
        jobenvs, jobzip, jobdata = {}, '', ''
        jobdict = {'prefix':'a/b', 'scheduler':{}, 'input':[],
                   'worker':"w", 'owner':"o", 'nr_reduces':"2"}
        jobpack = JobPack(jobdict, jobenvs, jobzip, jobdata)
        status, response = loads(self.disco.request('/disco/job/new', jobpack.dumps()))
        self.assertEquals(status, 'error')
        self.assertGreater(response.find("invalid prefix"), 0)

        jobdict = {'prefix':'a.b', 'scheduler':{}, 'input':[],
                   'worker':"w", 'owner':"o", 'nr_reduces':"2"}
        jobpack = JobPack(jobdict, jobenvs, jobzip, jobdata)
        status, response = loads(self.disco.request('/disco/job/new', jobpack.dumps()))
        self.assertEquals(status, 'error')
        self.assertGreater(response.find("invalid prefix"), 0)
