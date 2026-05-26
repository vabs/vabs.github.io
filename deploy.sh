#!/bin/bash

# Deployment is handled automatically by GitHub Actions (.github/workflows/deploy.yml).
# Pushing to master triggers a build and deploy to GitHub Pages.
#
# Prerequisites (one-time setup):
#   In the GitHub repo Settings → Pages:
#     - Source: GitHub Actions
#
# This script is kept for local preview only.

echo -e "\033[0;32mStarting local preview...\033[0m"
hugo server
