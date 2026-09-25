# -*- coding: utf-8 -*-

class GnrCustomWebPage(object):
    def main_root(self, root, **kwargs):
        records = self.db.table('dbrecords.test').query(
            columns='$ts,$description', order_by='$ts').fetch()
        root.h1(f'{len(records)} records', text_align='center')
        for r in records:
            root.div(f"{r['ts']:%Y-%m-%d %H:%M:%S} {r['description']}",
                     text_align='center')
