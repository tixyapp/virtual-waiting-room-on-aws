# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
This module provides a shared factory for creating Redis client connections.

Supports two secret formats stored in AWS Secrets Manager:
  - JSON (ElastiCache Serverless / RBAC):  {"username": "...", "password": "..."}
  - Plain string (legacy provisioned ElastiCache / password-only AUTH): "..."
"""

import json
import os
import redis


def get_redis_client(secrets_client, secret_name_prefix: str) -> redis.Redis:
    """
    Create and return a configured Redis client.

    Reads REDIS_HOST and REDIS_PORT from environment variables.
    Fetches credentials from Secrets Manager at ``{secret_name_prefix}/redis-auth``.

    The secret value may be either:
      - A JSON string: ``{"username": "waitingroom", "password": "..."}``
        Used with ElastiCache Serverless (RBAC / ACL authentication).
      - A plain string password: ``"..."``
        Used with legacy provisioned ElastiCache (password-only AUTH).
    """
    redis_host = os.environ["REDIS_HOST"]
    redis_port = os.environ["REDIS_PORT"]

    secret_string = secrets_client.get_secret_value(
        SecretId=f"{secret_name_prefix}/redis-auth"
    ).get("SecretString")

    try:
        secret = json.loads(secret_string)
        username = secret.get("username", "default")
        password = secret.get("password")
    except (json.JSONDecodeError, TypeError):
        # Legacy plain-string password (provisioned ElastiCache)
        username = None
        password = secret_string

    return redis.Redis(
        host=redis_host,
        port=redis_port,
        ssl=True,
        decode_responses=True,
        username=username,
        password=password,
    )
