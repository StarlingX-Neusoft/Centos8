#!/usr/bin/python

import sys

FN=sys.argv[1]
variables={}
variables['config_opts']={}
#execfile( FN, variables )
with open(FN) as f:
    code = compile(f.read(), FN, 'exec')
    exec(code, variables)
print(variables['config_opts']['yum.conf'])
