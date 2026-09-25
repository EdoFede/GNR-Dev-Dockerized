# -*- coding: utf-8 -*-
# Shows the Genropy version in use and whether it comes from a git checkout,
# detected the same way as `gnr dev bugreport <instance>`.

import os
import shutil
import subprocess

import gnr


def git_command(path, cmd):
    try:
        result = subprocess.run(['git', '-C', path] + cmd,
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None


class GnrCustomWebPage(object):
    def main_root(self, root, **kwargs):
        info = self.framework_info()
        box = root.div(margin='20px', font_family='monospace')
        box.h1('Genropy version')
        for label, value in info:
            row = box.div(margin_bottom='4px')
            row.span('%s: ' % label, font_weight='bold')
            row.span(str(value), _class='version_%s' % label)

    def framework_info(self):
        info = [('genropy_version', gnr.VERSION),
                ('framework_path', os.path.dirname(gnr.__file__))]
        if not shutil.which('git'):
            info.append(('genropy_from_git', 'unknown (git not available)'))
            return info
        framework_path = os.path.dirname(gnr.__file__)
        branch = git_command(framework_path, ['rev-parse', '--abbrev-ref', 'HEAD'])
        if branch:
            info += [('genropy_from_git', True),
                     ('genropy_git_branch', branch),
                     ('genropy_git_commit', git_command(framework_path, ['rev-parse', 'HEAD']))]
        else:
            info.append(('genropy_from_git', False))
        return info
