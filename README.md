# kube-app-testing

This script builds and tests a helm chart using either a KinD cluster, or a full Giant Swarm tenant
cluster. The only required parameter is `[chart name]`, which needs to be a name of the chart which
is present in directory `helm/`.

Running `pytest` based tests is optional, but recommended for app specific tests. For that purpose
we have a related [`pytest-helm-charts`](https://github.com/giantswarm/pytest-helm-charts)
plugin, which is tuned to work with `kube-app-testing.

## Installation

Checkout the repo and make `kube-app-testing.sh` executable and visible in your `$PATH`.

## Usage

Type:

```bash
kube-app-testing.sh -h
```

### With docker

```
docker build -t kat .
docker run --rm -it \
  --name kat \
  --network host \
  --mount type=bind,source=$HOME/.config/gsctl,target=/root/.config/gsctl \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  --mount type=bind,source=$PWD,target=$PWD,bind-propagation=rslave \
  --mount type=bind,source=/home/gerald/code/kube-app-testing/kube-app-testing.sh,target=/usr/local/bin/kube-app-testing.sh,bind-propagation=rslave \
  --workdir $PWD \
  kat bash
```

## How it works

There are 2 main modes:

### Just cluster mode

In the `-j` mode, a generic purpose cluster with `app-operator`, `chart-operator` and `chart-museum` is
create. No chart checking, validation or testing is done. Such cluster might be useful for custom
testing applications during development.

### Chart test mode

In the mode selected with `-c` switch, cluster is created as above, but also full chart validation and
testing is performed.

A single test cycle works as below:

1. Chart is validated and source files are templated using [`architect`](https://github.com/giantswarm/architect)
1. Linting is run using [chart-testing](https://github.com/helm/chart-testing).
1. Chart is built using `helm`
1. The following loop is run for every test config file present in `helm/[app]/ci/*yaml`. If there
   are no config files, the loop is started just once, without any config.
    1. New kubernetes cluster is created. Flag `-t` specified the type of the cluster.
       Supported values are `kind` and `giantswarm`.
       Specifying `kind` will create a kind-cluster using an embedded kind config
       file. You can override the config file using command line option `-i`.
       Specifying `giantswarm` utilizes `gsctl` to create a giantswarm cluster. Check out
       [GSCTL Environment configuration](https://docs.giantswarm.io/reference/gsctl/#configuration).
       When the cluster is up, `app-operator`,
       `chart-operator` and `chart-museum` are deployed.
    1. set `--no-external-kube-api` to disable opening the kubernetes api of a `giantswarm`
       cluster to the internet. (Usually only required where VPN is not available)
    1. If there's a file `helm/[chart name]/ci/pre-test-hook.sh`, it is executed. The
       `KUBECONFIG` variable is set to point to the test cluster for the script execution.
    1. Chart is pushed to the `chart-musuem` repository in the cluster.
    1. The App CR is created to deploy the application.
    1. If the directory `test/kat` exists at the top level of repository, python tests are
       started by executing the command:

       ```bash
       pipenv run pytest \
         --cluster-type existing \
         --kube-config /kube.config \
         --values-file ../../${config_file} \
         --chart-path \"helm/${chart_name}\" \
         --chart-version ${CHART_VERSION} \
         --chart-extra-info \"external_cluster_type=${CLUSTER_TYPE}\" \
         --log-cli-level info \
         --junitxml=../../${test_res_file}"
       ```

       Test results are saved in the directory `test-results/` in junit format
       for each of the test runs.

    1. If `-k` was given as command line option, the program exits keeping the test cluster.

## Requirements

Following tools must be installed in the system:

- kind
- helm
- curl
- jq
- gsctl

## Development setup for functional tests with python

*Hint: When you develop your tests intended to run with `pytest`, you can shorten you test-feedback
loop considerably by not running the full tool every single time, but just executing
`pytest` the same way the tool does.*

To start working on tests for a new project, that has a helm chart, but no
python tests, follow this steps:

1. Make sure you have `python 3.7` installed and selected as default python interpreter,
   then run

   ```bash
   pip install pipenv
   ```

2. Go to your application repo, create the directory `test/kat` and `cd` to it

   ```bash
   mkdir -p test/kat
   cd test/kat
   ```

3. Run  to create a `pipenv` managed project.

   ```bash
   pipenv --python 3.7
   ```

4. Install `pytest` and basic recommended libs in the `pipenv` virtual environment:

   ```bash
   pipenv install pytest-helm-charts
   ```

   Commit `Pipfile` and `Pipfile.lock` files.

5. Write your tests. This project is meant to use `pytest` with `pytest-helm-charts`, so
   look there for docs.

6. Use the tool to create a `kind` cluster you can use for your testing. Ask to not delete it
   by passing `-k` option. You can also skip running `pytest` based tests by passing `-s`:

   ```bash
   kube-app-testing.sh -c [app] -k [-s]
   ```

7. Now you're good to directly execute your tests against the test cluster:

   ```bash
   pipenv run pytest \
      --kube-config /tmp/kind_test/kubei.config \
      --chart-path \"helm/[app]\" \
      --values-file [""|../../[app]/ci/[config_file.yaml]
      --cluster-type existing \
      --chart-extra-info \"external_cluster_type=[kind|giantswarm]\" \
      --log-cli-level info
   ```

## Integration with CircleCI

Integration with CircleCI requires a job definition similar to the one below. Note that the last step in the job
is important to ensure any dangling resources are removed if a run fails midway through.

You'll also have to export your desired `GSCTL_ENDPOINT` and `GSCTL_AUTH_TOKEN` when testing on a `giantswarm` cluster.
Check out [GSCTL Environment configuration](https://docs.giantswarm.io/reference/gsctl/#configuration)

```yaml
jobs:
  run_kat_tests:
    machine:
      image: ubuntu-1604:201903-01
    working_directory:
      ~/giantswarm-todo
    steps:
      - restore_cache:
          key: repo-{{ .Environment.CIRCLE_SHA1 }}-<< pipeline.git.tag >>
      - run: pyenv versions
      - run: pyenv global 3.7.0
      - run: python --version
      - run: pip install pipenv aws-shell
      - run: curl -Lo /tmp/kind "https://github.com/kubernetes-sigs/kind/releases/download/v0.7.0/kind-$(uname)-amd64"
      - run: chmod +x /tmp/kind
      - run: curl -Lo /tmp/helm.tar.gz https://get.helm.sh/helm-v2.16.5-linux-amd64.tar.gz
      - run: tar zxf /tmp/helm.tar.gz -C /tmp && mv /tmp/linux-amd64/helm /tmp/helm
      - run: /tmp/helm init -c
      - run: curl -Lo /tmp/kube-app-testing.sh -q https://raw.githubusercontent.com/giantswarm/kube-app-testing/master/kube-app-testing.sh
      - run: chmod +x /tmp/kube-app-testing.sh
      - run: curl -Lo /tmp/kubectl https://storage.googleapis.com/kubernetes-release/release/v1.18.0/bin/linux/amd64/kubectl
      - run: chmod +x /tmp/kubectl
      - run: curl -L https://github.com/giantswarm/gsctl/releases/download/0.24.3/gsctl-0.24.3-linux-amd64.tar.gz | tar -zx --strip-components=1 --directory=/tmp gsctl-0.24.3-linux-amd64/gsctl
      - run: PATH="/tmp:$PATH" kube-app-testing.sh -c giantswarm-todo-app -t giantswarm --cluster-name ci-<insert-app-name-here> -r ${GS_RELEASE} --availability-zone ${GS_AVAILABILITY_ZONE}
      - store_test_results:
          path: test-results
      - store_artifacts:
          path: test-results
      - run:
          name: Cleanup resources
          command: PATH="/tmp:$PATH" kube-app-testing.sh -a ${GS_API_KEY} --force-cleanup
          when: on_fail

workflows:
  version: 2
  build:
    jobs:
      - run_kat_tests:
          requires:
            - <add any jobs which must run first here>
          filters:
            tags:
              only: /^v.*/
```

Requirements:

- for running on AWS:
  - IAM user with `ec2:AuthorizeSecurityGroupIngress` and `ec2:DescribeSecurityGroups` **in the tenant cluster account**.
  - IAM user's access key & key ID must be added as environment variables to the CircleCI project. They should be called `AWS_ACCESS_KEY_ID` & `AWS_SECRET_ACCESS_KEY`.
  - The AWS CLI is required when testing against AWS.
