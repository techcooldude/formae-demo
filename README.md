# Formae Demo

Example infrastructure-as-code configurations using [Formae](https://docs.formae.io) and the [Pkl](https://pkl-lang.org) configuration language.

## Prerequisites

- [Formae CLI](https://hub.platform.engineering/setup/formae.sh) installed
- [Formae agent](https://docs.formae.io/en/latest/agent) running and accessible
- AWS credentials configured (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
- GitHub CLI (`gh`) authenticated for the CI pipeline example

## Examples

### CI/CD Pipeline (`ci-pipeline`)

Bootstraps a full GitHub Actions CI/CD pipeline for deploying AWS infrastructure into any repository.

**Creates:**
- `apply.yml` — manually triggered workflow to deploy to staging or production
- `destroy.yml` — manually triggered destroy with a `destroy` confirmation guard
- Staging environment — deploys from `release/*` and `develop` branches
- Production environment — 15-minute approval wait, no self-review, deploys from `main` only
- Repository-level variables (`PROJECT_NAME`, `AWS_DEFAULT_REGION`, `FORMAE_AGENT_URL`)

**Run:**
```bash
cd ci-pipeline

export GHA_OWNER=your-github-username
export GHA_REPO=your-infrastructure-repo

formae apply --mode reconcile --yes main.pkl
```

**GitHub Secrets required in your infrastructure repo:**
| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |

```bash
gh secret set AWS_ACCESS_KEY_ID     --repo your-github-username/your-infrastructure-repo
gh secret set AWS_SECRET_ACCESS_KEY --repo your-github-username/your-infrastructure-repo
```

---

### EC2 VM Deployment (`ec2-vm`)

Provisions an EC2 virtual machine with a security group, SSH access, and an optional startup script.

**Creates:**
- EC2 instance (configurable type, AMI, region)
- Security group with SSH + HTTP/HTTPS ingress
- Elastic IP for a stable public address
- CloudWatch basic monitoring alarm

**Run:**
```bash
cd ec2-vm

export AWS_ACCESS_KEY_ID=your-key-id
export AWS_SECRET_ACCESS_KEY=your-secret-key

formae apply --mode reconcile --yes main.pkl
```

**Destroy:**
```bash
formae destroy --yes main.pkl
```

**Customise in `vars.pkl`:**
| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `us-east-1` | AWS region |
| `instanceType` | `t3.micro` | EC2 instance type |
| `amiId` | Amazon Linux 2023 | AMI ID (region-specific) |
| `keyName` | — | Existing EC2 key pair name for SSH |
| `projectName` | `formae-demo-vm` | Tag prefix for all resources |

## Project Structure

```
formae-demo/
├── .github/workflows/
│   ├── apply.yml                     # Deploy workflow (manual trigger)
│   └── destroy.yml                   # Destroy workflow (manual trigger)
├── ci-pipeline/
│   ├── main.pkl                      # Pipeline entrypoint
│   ├── vars.pkl                      # Stack, target, region config
│   └── environment_resources.pkl     # Reusable environment + branch policy class
├── ec2-vm/
│   ├── main.pkl                      # VM deployment entrypoint
│   └── vars.pkl                      # Region, instance type, AMI, tags
└── README.md
```

## Resources

- [Formae documentation](https://docs.formae.io)
- [Formae AWS plugin](https://hub.platform.engineering)
- [Pkl language](https://pkl-lang.org/main/current/language-reference/index.html)
- [GitHub Actions plugin](https://hub.platform.engineering)
