#!/bin/bash
# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: Apache-2.0

command=$1
shift 1
text=$@
echo $text
# Could this script make use of the Vault agent and the agent's token after auto-auth to make a request to the transit engine?!?
