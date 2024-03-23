# offline_leaf
A shell script for offline work on an Overleaf project. Automatic synchronization and merging when online.

This uses Overleaf's [gitsync functionality](https://www.overleaf.com/learn/how-to/Git_Integration_and_GitHub_Synchronization)

# STEPS FOR USE

1. Go to your project in Overleaf
2. Get the project ID. For example, if your Overleaf project URL is https://www.overleaf.com/project/65cf7db8c9d209bdc5f3a039, the project ID is: 65cf7db8c9d209bdc5f3a039.
3. Navigate to the directory that you want your local Overleaf project to be located within. From a shell terminal at that location, do `git clone https://git.overleaf.com/[project id]`
4. Download `offline_leaf.sh` and `offline_leaf_config.sh` from this repository. Where you place these does not really matter; you could place the two files into the same directory that you cloned your Overleaf project into above. So you would see in that directory these three items: `[project id]`, `offline_leaf.sh`, and `offline_leaf_config.sh`. If you expect to work offline on more than one Overleaf project, you would be better off putting the `offline_leaf.sh' file in a separate place, and then passing to this script the location of the configuration file, but that doesn't need to be done. 
6. Modify `offline_leaf_config.sh` to contain the correct path to your Overleaf repository.
7. do `chmod +x offline_leaf.sh' and 'chmod +x offline_leaf_config.sh`.
8. cd into your Overleaf repository, and do `git config pull.rebase false` and `git config http.postBuffer 10485760`. To skip doing this for every Overleaf project you are working on, you can do `git config --global` with these two settings.
9. You will need to install fswatch. For macOS, where this was developed and tested, open a terminal and do `sudo port install fswatch` if you are using MacPorts. 
10. Now from whatever directory you placed the script, you can do `offline_leaf.sh /path_to_configuration_file/offline_leaf_config.sh`.


**Notes**

The script will continually poll the remote repository and let you know if it was able to synchronize your local changes. If there is a conflict, it will tell you about the conflict and how to manually edit the .tex file so that the changes are properly merged.

One thing that is somewhat inconvenient with Overleaf is synchronizing figures you are making for your Overleaf project. We have a similar script for synchronizing figure changes, called figleaf_sync, in a different github repository.

