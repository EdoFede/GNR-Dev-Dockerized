#!/usr/bin/env python
# encoding: utf-8

class Table(object):
    def config_db(self, pkg):
        tbl = pkg.table('test', pkey='id', name_long='!![en]Test', caption_field='description')
        self.sysFields(tbl)
        tbl.column('ts', dtype='DH', name_long='!![en]Date and time')
        tbl.column('description', name_long='!![en]Description')
