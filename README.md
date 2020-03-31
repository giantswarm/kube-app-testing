# kind-app-testing

This script builds and tests a helm chart using a kind cluster. The only required
parameter is `[chart name]`, which needs to be a name of the chart which is present
in directory `helm/`. 

## Usage

Type:

```bash
kind-app-testing.sh -h
```

## How it works

A single test cycle works like this. First, this creates a new kind cluster using
an embedded kind config file. You can override the config file using command line
option `-i`. When the cluster is up, `app-operator`, `chart-operator` and
`chart-museum` are deployed.

If there's a file `helm/[chart name]/si/pre-test-hook.sh`, it will be executed after
the cluster is ready to deploy the tested chart, but before it is deployed. The
`KUBECONFIG` variable is set to point to the test cluster for the script execution.
In the next step the chart is built, pushed to the `chart-musuem` repository in the
cluster and the App CR is created to deploy the application.
The last (and optional) step is to execute functional test. If the directory
`test/kind` is present in the top level directory, the command `pipenv run pytest`
is executed as the last step.

If there are YAML files present in the directory `helm/[chart name]/ci`, a full test
(starting with creation of a new clean cluster) will be executed for each one of them.
Test results are saved in the directory `test-results/` in junit format for each of
the test runs.

## Requirements

Following tools must be installed in the system:

- kind
- helm
- pipenv (able to create python 3.7 virtual envs)
