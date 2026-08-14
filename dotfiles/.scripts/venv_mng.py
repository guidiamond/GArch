from os import walk, path, listdir, getlogin
from os.path import isfile, join
import subprocess


USER = getlogin()
# onlyfiles = [f for f in listdir(mypath) if isfile(join(mypath, f))]
class VenvManager:
    def __init__(self):
        self.selected_option = "0"
        self.venv_path = path.abspath(f"/home/{USER}/.virtualenv")
        self.zshrc_file = path.abspath(f"/home/{USER}/.config/zsh/zshrc")
        self.select_menu()
        print("============================")
        self.run_option()

    def select_menu(self):
        options = ["add env", "select existing env", "exit"]
        for idx in range(len(options)):
            print("{0} => {1}".format(idx + 1, options[idx]))
        # choose virtual enviroment

        while (
            not self.selected_option.isdigit()
            or self.selected_option == "0"
            or (int(self.selected_option) > len(options))
        ):
            self.selected_option = input("\nChoose an Option: ")

    def run_option(self):
        self.selected_option = int(self.selected_option) - 1

        if self.selected_option == 0:
            self.opt1()

        elif self.selected_option == 1:
            self.opt2()

        elif self.selected_option == 2:
            print("bye")
            exit()

    def opt1(self):  # generate new python env
        # choose python version
        python_version = "0"
        while not (python_version == "2" or python_version == "3"):
            python_version = input("\nChoose a python version (2 | 3): ")
        env_name = "0"
        while env_name.isdigit():
            env_name = input("New env name: ")

        # save new env
        if python_version == "2":
            python_dir = "/usr/bin/python2"
        else:
            python_dir = "/usr/bin/python"

        create_env_cmd = "virtualenv --python={0} {1}/{2}".format(
            python_dir, self.venv_path, env_name
        )
        process = subprocess.Popen(create_env_cmd.split(), stdout=subprocess.PIPE)
        python_dir, _ = process.communicate()

    def opt2(self):
        dir_names = listdir(self.venv_path)
        for dir_idx in range(len(dir_names)):
            print("{0} => {1}".format(dir_idx + 1, dir_names[dir_idx]))
        selected_env = "0"
        while not selected_env.isdigit() or selected_env == "0":
            selected_env = input("\nChoose an Option: ")
        selected_env = int(selected_env) - 1
        self.save_new_env(dir_names[selected_env])

    def save_new_env(self, env_name):
        # new env dir eg: $HOME/.virtualenv/NEW_ENV
        venv_dir = "{0}/{1}".format(self.venv_path, env_name)
        # read zshrc file
        with open(self.zshrc_file, "r") as file:
            types_content = file.readlines()
        # find and replace the python_env export
        for l in range(len(types_content)):
            if types_content[l].find("export PYTHON_ENV") != -1:
                types_content[l] = 'export PYTHON_ENV="{0}"\n'.format(venv_dir)
        # save file
        with open(self.zshrc_file, "w") as file:
            file.writelines(types_content)


if __name__ == "__main__":
    venv = VenvManager()
