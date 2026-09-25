#!/usr/bin/env python
# encoding: utf-8
from gnr.app.gnrdbo import GnrDboTable, GnrDboPackage

class Package(GnrDboPackage):
    def config_attributes(self):
        return dict(comment='version package',
                    sqlschema='version',
                    sqlprefix=True,
                    name_short='Version',
                    name_long='Version',
                    name_full='Version')
                    
    def config_db(self, pkg):
        pass
        
class Table(GnrDboTable):
    pass
