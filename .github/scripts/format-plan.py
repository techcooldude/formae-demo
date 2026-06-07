#!/usr/bin/env python3
"""Format formae --simulate output as a Terraform-style plan summary."""
import re, sys

text = open('/tmp/formae-sim-raw.txt').read()

# Extract each resource's final action state (last occurrence wins)
resources = {}
for line in text.splitlines():
    m = re.search(
        r'(create|update|delete|replace) resource ([^:│├└\s][^:]+?)\s*:'
        r'\s*(Success|Failed|InProgress|NotStarted)',
        line
    )
    if m:
        action, name, status = m.group(1), m.group(2).strip(), m.group(3)
        resources[name] = (action, status)

creates  = sum(1 for a, _ in resources.values() if a == 'create')
updates  = sum(1 for a, _ in resources.values() if a == 'update')
deletes  = sum(1 for a, _ in resources.values() if a == 'delete')
replaces = sum(1 for a, _ in resources.values() if a == 'replace')

W     = 52
GREEN = '\033[32m'
YELL  = '\033[33m'
RED   = '\033[31m'
PURP  = '\033[35m'
RESET = '\033[0m'

SYM    = {'create': '+', 'update': '~', 'delete': '-', 'replace': '±'}
CLR    = {'create': GREEN, 'update': YELL, 'delete': RED, 'replace': PURP}
SUFFIX = {
    'create':  'will be created',
    'update':  'will be updated',
    'delete':  'will be destroyed',
    'replace': 'will be replaced',
}

print('═' * W)
print('  Formae Plan  ·  ec2-vm  ·  reconcile mode')
print('═' * W)
print()

if not resources:
    print('  No changes. Infrastructure is up-to-date.')
else:
    for action in ('create', 'update', 'replace', 'delete'):
        for name, (act, status) in sorted(resources.items()):
            if act != action:
                continue
            sym  = SYM[action]
            clr  = CLR[action]
            fail = f'  {RED}✗ FAILED{RESET}' if status == 'Failed' else ''
            print(f'  {clr}{sym} {name:<24}{RESET}  {SUFFIX[action]}{fail}')

print()
print('─' * W)
parts = []
if creates:  parts.append(f'{GREEN}{creates} to add{RESET}')
if updates:  parts.append(f'{YELL}{updates} to change{RESET}')
if deletes:  parts.append(f'{RED}{deletes} to destroy{RESET}')
if replaces: parts.append(f'{PURP}{replaces} to replace{RESET}')
if not parts:
    parts = [f'{GREEN}0 to add{RESET}', f'{YELL}0 to change{RESET}', f'{RED}0 to destroy{RESET}']
print('  Plan: ' + ', '.join(parts))
print('═' * W)
