# offleaf.sh & figleaf.sh
**offleaf.sh**: A shell script for offline work on a local clone of an Overleaf project repository. Automatic synchronization and merging when online. Target use is when there is inconsistent connectivity, no connectivity, or you prefer editing with local machine LaTeX environment.

**figleaf.sh**: A shell script for automatic conversion of vector illustration files to bitmap and optimized vector for synchronization to an Overleaf project. Target use is for writing projects with enough figures/frequent edit cycles, so that manual uploads to Overleaf become too time consuming.


# offleaf.sh:

This uses Overleaf's [gitsync functionality](https://www.overleaf.com/learn/how-to/Git_Integration_and_GitHub_Synchronization)

# STEPS FOR USE of offleaf.sh

1. Install git and several needed tools. In macOS, using MacPorts, this would involve
    `xcode-select --install` (to get git). Then
    install macports from https://www.macports.org/. Finally:
    `sudo port install git ghostscript fswatch convert` (ghostscript and convert needed by figleaf.sh only).
    For Windows machines, a useful terminal with git functionality can be obtained via https://gitforwindows.org/.
3. Go to your project in Overleaf
4. Get the project ID. For example, if your Overleaf project URL is https://www.overleaf.com/project/65cf7db8c9d209bdc5f3a039, the project ID is: 65cf7db8c9d209bdc5f3a039.
5. Navigate to a directory that you want your local Overleaf project to be located within: Now create that directory, which will contain a clone of the Overleaf repository as well as a configuration file you'll need to edit in a following step. From a shell terminal in this new directory, do `git clone https://git.overleaf.com/[project id]`
6. Download `offleaf.sh`, `offleaf_config.sh`, and `leaf_common.sh` from this repository (and `figleaf.sh` if you'll be using that). Put these into a directory that you then add to your executable path, or where you will execute them. Move `offleaf_config.sh` into the same directory that also contains your Overleaf repository (so at the same level, but not within, your Overleaf repository).  
8. Edit `offleaf_config.sh` to set GIT_PATH to the full path to the Overleaf repository (instructions for other variables: see section on `figleaf.sh`). 
9. Open a terminal to where `offleaf.sh` is, and do `chmod +x offleaf.sh` (and same for `figleaf.sh` if it will be used).
10. cd into your Overleaf repository, and do `git config pull.rebase false` and `git config http.postBuffer 10485760`. To skip doing this for every Overleaf project you are working on, you can do `git config --global` with these two settings.
11. Add a .gitignore file to your Overleaf repository. I've included a file with suggested ignores (`GITIGNORE_CONTENTS.txt`): to use, just copy its contents into a file called `.gitignore` within the top level of your Overleaf repository. Then do `git add .gitignore`, then `git commit -m 'new .gitignore'`, and finally `git push`.
12. Now from the parent directory of your Overleaf repository, you can run `offleaf.sh offleaf_config.sh`.


**Notes**

The script will continually poll the remote repository and let you know if it was able to synchronize your local changes. If there is a conflict, it will tell you about the conflict and how to manually edit the .tex file so that the changes are properly merged.


# figleaf.sh

One thing that is somewhat inconvenient with Overleaf is synchronizing figures you are making for your Overleaf project. After, for example, editing a large Adobe Illustrator file, you may need to optimize the pdf to a smaller size, and/or convert the file to a bitmapped file type so that compile times for Overleaf are not excessively long (they quickly become so with multiple large vector files). You then need to go to your Overleaf project, and select the folder for the vector version of your figures, click on it and hit upload, navigate to your file, and upload, and repeat for the bitmap version. That gets tedious quickly.

figleaf.sh monitors the vector masters (Adobe Illustrator .ai and .pdf file types presently), and when it detects a change, optimizes the pdf and creates a .jpg file as well, and then pushes these both to the associated Overleaf project, so your collaborators and you have fast and easy updates to figures, particularly useful in the final phases of grant or publication preparations when changes are being made with high frequency.

# STEPS FOR USE of figleaf.sh

1. Follow the instructions for offleaf.sh above
2. In the directory where you keep your figure file masters, create `/watched` and move all illustration original files to that subdirectory. For collaborative efforts, it's best to make this within a cloud-based drive.
3. Edit your `offleaf_config.sh` file with the correct location of this new subdirectory
4. Create a `/ignored_by_fswatch` subdirectory at the same level as `/watched`; Create `prepress_bitmap` and `prepress_vector` subdirectories below this one. 
5. Create `/figures/vector` and `/figures/bitmap` in your local copy of your Overleaf project. You will need to add these two subdirectories to your graphics path for compiling your .tex files in Overleaf.
6. Modify `offleaf_config.sh` to indicate the location of the `/watched` directory created above.
7. Now from the parent directory of your Overleaf repository, you can run `figleaf.sh offleaf_config.sh`.


**Notes**

Unlike offleaf.sh, there is no automatic merging function in this script. It is assuming only one person is actively making figure changes.
Since these files are often binary files, auto merge would be a bad idea. If a conflict occurs the script will exit.

Because the code is assuming illustration masters are maintained outside of Overleaf, it pulls from the repository before pushing, but it does not propagate newly edited files back to the directories where the masters are maintained.
