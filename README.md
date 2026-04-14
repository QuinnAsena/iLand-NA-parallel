# iLand-NA-parallel
Presentation on running iLand in parallel on an HPC

## Scripts

The `scripts/` directory contains the files used to configure and run iLand simulations in parallel on an HPC cluster:

- **`run_iland_csv_cpxml.sh`** – Bash script that reads simulation parameters from `iland_reps.csv`, copies and modifies the base XML project file for each parameter combination and replicate, runs the iLand model executable, and cleans up temporary files.
- **`iland_reps.csv`** – CSV file defining the parameter combinations (species parameters, climate model, fire return interval, epsilon, DBH threshold, and scenario ID) to be iterated over by the run script.
- **`CPCRW_hist_spinup_derecho.xml`** – Base iLand project file for the CPCRW historical spinup simulations. The run script copies and modifies this file for each scenario.
- **`saveWorkflow.js`** – iLand JavaScript workflow file that handles model snapshots, screenshots, and optional deterministic disturbance events during a simulation run.

### Contributing

Contributions to the scripts are welcome. To contribute:

1. Fork the repository and create a new branch for your changes.
2. Follow the existing code style and naming conventions used in the scripts.
3. Test your changes on an HPC environment before submitting.
4. Open a pull request with a clear description of what your changes do and why.

If you are adding a new script, please add a brief description of it to this README under the **Scripts** section.
