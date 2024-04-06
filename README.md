# offleaf.sh & figleaf.sh
**offleaf.sh**: A shell script for offline work on an Overleaf project. Automatic synchronization and merging when online.

**figleaf.sh**: A shell script for automatic conversion of vector illustration files to bitmap and optimized vector for synchronization to an Overleaf project.


# offleaf.sh:

This uses Overleaf's [gitsync functionality](https://www.overleaf.com/learn/how-to/Git_Integration_and_GitHub_Synchronization)

# STEPS FOR USE

1. Install git and several needed tools. In macOS, using MacPorts, this would involve
    `xcode-select --install` (to get git). Then
    install macports from https://www.macports.org/. Finally:
    `sudo port install git ghostscript fswatch convert`
    For Windows machines, a useful terminal with git functionality can be obtained via https://gitforwindows.org/.
3. Go to your project in Overleaf
4. Get the project ID. For example, if your Overleaf project URL is https://www.overleaf.com/project/65cf7db8c9d209bdc5f3a039, the project ID is: 65cf7db8c9d209bdc5f3a039.
5. Navigate to the directory that you want your local Overleaf project to be located within. From a shell terminal at that location, do `git clone https://git.overleaf.com/[project id]`
6. Download `offleaf.sh` and `offleaf_config.sh` from this repository. Where you place these does not really matter; you could place the two files into the same directory that you cloned your Overleaf project into above. So you would see in that directory these three items: `[project id]`, `offleaf.sh`, and `offleaf_config.sh`. If you expect to work offline on more than one Overleaf project, you would be better off putting the `offleaf.sh' file in a separate place, and then passing to this script the location of the configuration file, but that doesn't need to be done. 
7. Modify `offleaf_config.sh` to contain the correct path to your Overleaf repository.
8. do `chmod +x offleaf.sh' and 'chmod +x offleaf_config.sh`.
9. cd into your Overleaf repository, and do `git config pull.rebase false` and `git config http.postBuffer 10485760`. To skip doing this for every Overleaf project you are working on, you can do `git config --global` with these two settings.
10. Add a .gitignore file to your Overleaf repository. I've included a sample one to include in this repository: to use, just copy its contents into a file called .gitignore. Then do `git add .gitignore`, then `git commit -m 'new .gitignore'`, and finally `git push .gitignore`. 
12. Now from whatever directory you placed the script, you can do `offleaf.sh /path_to_configuration_file/offleaf_config.sh`.


**Notes**

The script will continually poll the remote repository and let you know if it was able to synchronize your local changes. If there is a conflict, it will tell you about the conflict and how to manually edit the .tex file so that the changes are properly merged.


# figleaf.sh

One thing that is somewhat inconvenient with Overleaf is synchronizing figures you are making for your Overleaf project. After, for example, editing a large Adobe Illustrator file, you may need to optimize the pdf to a smaller size, and/or convert the file to a bitmapped file type so that compile times for Overleaf are not excessively long (they quickly become so with multiple large vector files). You then need to go to your Overleaf project, and select the folder for the vector version of your figures, click on it and hit upload, navigate to your file, and upload, and repeat for the bitmap version. That gets tedious quickly.

figleaf.sh monitors the vector masters (Adobe Illustrator .ai and .pdf file types presently), and when it detects a change, optimizes the pdf and creates a .jpg file as well, and then pushes these both to the associated Overleaf project, so your collaborators and you have fast and easy updates to figures, particularly useful in the ``terminal buzz'' phase of grant or publication preparations.


