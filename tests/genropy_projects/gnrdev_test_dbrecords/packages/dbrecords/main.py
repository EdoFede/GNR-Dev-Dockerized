#!/usr/bin/env python
# encoding: utf-8
from gnr.app.gnrdbo import GnrDboTable, GnrDboPackage

class Package(GnrDboPackage):
    def config_attributes(self):
        return dict(comment='dbrecords package',
                    sqlschema='dbrecords',
                    sqlprefix=True,
                    name_short='Dbrecords',
                    name_long='Dbrecords',
                    name_full='Dbrecords')

    def config_db(self, pkg):
        pass

class Table(GnrDboTable):
    pass
