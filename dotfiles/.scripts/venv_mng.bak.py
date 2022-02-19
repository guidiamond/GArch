from os import walk, path, listdir
from os.path import isfile, join
import subprocess

venv_path = path.abspath("/home/damn/.virtualenv")
zshrc_file = path.abspath("/home/damn/.config/zsh/zshrc")
exported_alias = "export PYTHON_ENV=\"$HOME/.virtualenv"

def save_new_env(env_name):
    venv_dir = "{0}/{1}".format(venv_path,env_name)
    with open(zshrc_file, 'r') as file:
        types_content = file.readlines()
    for l in range(len(types_content)):
        if types_content[l].find("export PYTHON_ENV") != -1:
            types_content[l] = "export PYTHON_ENV=\"$HOME/.virtualenv/{0}\"\n".format(env_name)
    with open(zshrc_file, 'w') as file:
        file.writelines(types_content)
        # types_content.insert(export_index+1,generate_types_body(use_case_name))
        # file.seek(0)
        # for l in range(len(types_content)):
            # file.write(types_content[l])


def opt1():
    print("============================")
    selected_python_version = '0'
    while not (selected_python_version == '2' or selected_python_version == '3'):
        selected_python_version = input("\nChoose a python version (2 | 3): ")
    new_env_name = '0'
    while (new_env_name.isdigit()):
        new_env_name=input("New env name: ")
    which_python_cmd = "which python{0}".format(selected_python_version)
    process = subprocess.Popen(which_python_cmd.split(), stdout=subprocess.PIPE)
    python_dir, error = process.communicate()
    python_dir = python_dir.decode().replace('/\s/g', '')
    create_env_cmd = "virtualenv --python={0} {1}/{2}".format(python_dir, venv_path, new_env_name)
    process = subprocess.Popen(create_env_cmd.split(), stdout=subprocess.PIPE)
    python_dir, error = process.communicate()



def opt2():
    print("============================")
    dir_names = listdir(venv_path)
    for dir_idx in range(len(dir_names)):
        print("{0} => {1}".format(dir_idx+1,dir_names[dir_idx]))
    selected_env = '0'
    while  (not selected_env.isdigit() or selected_env == '0'):
        selected_env = input("\nChoose an Option: ")
    selected_env = int(selected_env) - 1
    save_new_env(dir_names[selected_env])

    # f = []
    # for (dirpath) in 


selected_option = '0'
options = ["add env", "select existing env", "exit"]
for optionIdx in range(len(options)):
    print("{0} => {1}".format(optionIdx+1,options[optionIdx]))

while  (not selected_option.isdigit() or selected_option == '0'):
    selected_option = input("\nChoose an Option: ")

selected_option = int(selected_option)-1

if (selected_option == 0):
    opt1()

if (selected_option == 1):
    opt2()
    # onlyfiles = [f for f in listdir(mypath) if isfile(join(mypath, f))]

if (selected_option == 2):
    print("bye")
    exit()


# onlyfiles = [f for f in listdir(mypath) if isfile(join(mypath, f))]
