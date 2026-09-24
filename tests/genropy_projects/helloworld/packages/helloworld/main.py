#!/usr/bin/env python
# encoding: utf-8
from gnr.app.gnrdbo import GnrDboTable, GnrDboPackage

class Package(GnrDboPackage):
    def config_attributes(self):
        return dict(comment='helloworld package',sqlschema='helloworld',sqlprefix=True,
                    name_short='Helloworld', name_long='Helloworld', name_full='Helloworld')
                    
    def config_db(self, pkg):
        pass
        
class Table(GnrDboTable):
    pass
