# Sock Shop

**Domain:** Cloud Native
**Version:** 1.0.0
**Tier:** Official
**Maintainer:** ACE Core Team

## Overview

Sock Shop is a canonical cloud-native microservices demo originally created by Weaveworks.
It implements an e-commerce application with 13 independent services.

## Architecture

```
browser → front-end (React)
              ├── catalogue → catalogue-db (MySQL)
              ├── carts → carts-db (MongoDB)
              ├── orders → orders-db (MongoDB)
              │               └── rabbitmq → queue-master → shipping
              ├── user → user-db (MongoDB)
              └── payment
```

## Microservices

| Service | K8s Label | Kind | Criticality |
|---------|----------|------|-------------|
| front-end | name=front-end | Deployment | high |
| carts | name=carts | Deployment | high |
| carts-db | name=carts-db | Deployment | high |
| catalogue | name=catalogue | Deployment | high |
| catalogue-db | name=catalogue-db | Deployment | high |
| orders | name=orders | Deployment | high |
| orders-db | name=orders-db | Deployment | high |
| payment | name=payment | Deployment | high |
| queue-master | name=queue-master | Deployment | medium |
| rabbitmq | name=rabbitmq | Deployment | medium |
| shipping | name=shipping | Deployment | medium |
| user | name=user | Deployment | high |
| user-db | name=user-db | Deployment | high |

## Install

```bash
helm install sock-shop app-charts/charts/sock-shop \
  --namespace sock-shop --create-namespace --timeout 30m --wait
```

Health probe: `http://front-end.sock-shop.svc.cluster.local:80` → expects HTTP 200.

## Supported Faults

- `pod-delete` — tests restart recovery
- `pod-cpu-hog` — tests CPU throttling response
- `pod-memory-hog` — tests OOM behavior
- `pod-network-loss` — tests inter-service network partition
- `k8s-config-mutation` — tests misconfiguration detection
