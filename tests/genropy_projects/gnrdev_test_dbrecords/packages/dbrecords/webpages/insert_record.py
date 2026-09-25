# -*- coding: utf-8 -*-
from datetime import datetime

RECORD_TEXT = 'gnrdev test record'

class GnrCustomWebPage(object):
    def main_root(self, root, **kwargs):
        tbl = self.db.table('dbrecords.test')
        record = tbl.newrecord(ts=datetime.now(), description=RECORD_TEXT)
        tbl.insert(record)
        self.db.commit()
        root.h1('Record inserted', text_align='center')
        root.div(f"{record['ts']:%Y-%m-%d %H:%M:%S} {record['description']}",
                 text_align='center')
