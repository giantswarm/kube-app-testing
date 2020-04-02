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

A single test cycle works as below:

1. If there's an old test cluster, it is deleted.
1. Chart is validated and source files are templated using [`architect`](https://github.com/giantswarm/architect)
    1. If `-l` option is given, linting is run using [chart-testing](https://github.com/helm/chart-testing)
1. Chart is built using `helm`
1. The following loop is run for every test config file present in `helm/[app]/ci/*yaml`. If there
   are no config files, the loop is started just once, without any config.
    1. New `kind` cluster is created using an embedded kind config file. You can override
       the config file using command line option `-i`. When the cluster is up, `app-operator`,
       `chart-operator` and `chart-museum` are deployed.
    1. If there's a file `helm/[chart name]/si/pre-test-hook.sh`, it is executed. The
       `KUBECONFIG` variable is set to point to the test cluster for the script execution.
    1. Chart is pushed to the `chart-musuem` repository in the cluster.
    1. The App CR is created to deploy the application.
    1. If the directory `test/kind` exists at the top level of repository, python tests are
       started by executing the command:

       ```bash
       pipenv run pytest \
       --kube-config /kube.config \
       --chart-name ${chart_name} \
       --values-file ../../${config_file} \
       --junitxml=../../${test_res_file}
       ```

       As you can see, test results are saved in the directory `test-results/` in junit format
       for each of the test runs.

    1. If `-k` was given as command line option, the program exits keeping the test cluster.

## Requirements

Following tools must be installed in the system:

- kind
- helm
- curl

## Development setup for functional tests with python

When you develop your tests intended to run with `pytest`, you can shorten you test-feedback
loop considerably by not running the full tool every single time, but just executing
`pytest` the same way the tool does.

In order to do that and start working on a new project, that has a helm chart, but no
python tests, follow this steps:

1. Make sure you have `python 3.7` installed and selected as default python interpreter,
   then run

   ```bash
   pip install pipenv
   ```

2. Go to your application repo, create the directory `test/kind` and `cd to it

   ```bash
   mkdir test/kind
   cd test/kind
   ```

3. Run  to create a `pipenv` managed project.

   ```bash
   pipenv --python 3.7
   ```

4. Install `pytest` and basic recommended libs in the `pipenv` virtual environment:

   ```bash
   pipenv install pytest pytest-rerunfailures kubetest kubernetes
   ```

   Commit `Pipfile` and `Pipfile.lock` files.

5. Write your tests. To get started faster, you might want to include this
   [`conftest.py`](https://github.com/giantswarm/giantswarm-todo-app/blob/master/test/kind/conftest.py)
   file to get fixtures offering you the tested chart name and the path and values loaded
   from `helm/[app]/ci*.yaml` file used for this test run.

6. Use the tool to create a `kind` cluster you can use for your testing. Ask to not delete it
   by passing `-k` option:

   ```bash
   kind-app-testing.sh -c [app] -k
   ```

7. Now you're good to directly execute your tests against the test cluster:

   ```bash
   pipenv run pytest \
      --kube-config /tmp/kind_test/kubei.config \
      --chart-name [app] \
      --values-file [""|../../[app]/ci/[config_file.yaml]
   ```

## Integration with circleci

Sample integration config can be found in [giantswarm-todo-app](https://github.com/giantswarm/giantswarm-todo-app/blob/f45fac5bd107c193d6e82a4da81e8164fa6018ea/.circleci/config.yml#L40).
