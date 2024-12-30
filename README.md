# liquibase-spring-boot



 Liquibase provides an RPM package that you can install on Red Hat-based systems, allowing you to run Liquibase as a shell command. Here's how you can install and set it up:

1. Import the Liquibase Public Key

First, import the Liquibase public key to ensure the authenticity of the package:

bash
Copy code
sudo rpm --import https://repo.liquibase.com/liquibase.asc
2. Install yum-utils

Ensure that yum-utils is installed to manage repositories:

bash
Copy code
sudo yum install -y yum-utils
3. Add the Liquibase Repository

Add the Liquibase repository to your system:

bash
Copy code
sudo yum-config-manager --add-repo https://repo.liquibase.com/repo-liquibase-com.repo
4. Install Liquibase

Now, install Liquibase using yum:

bash
Copy code
sudo yum install liquibase
5. Verify the Installation

After installation, verify that Liquibase is installed correctly by checking its version:

bash
Copy code
liquibase --version
This should display the installed version of Liquibase, confirming that the installation was successful.

6. Running Liquibase Commands

With Liquibase installed, you can execute commands directly from the shell. For example, to update your database using a changelog file:

bash
Copy code
liquibase --changeLogFile=/path/to/db.changelog-master.yaml update
Ensure that you have the necessary database drivers and configurations set up for your specific database.

For more detailed information and additional installation options, refer to the official Liquibase documentation: 

Alternatives to RPM
If creating an RPM seems too complex or unnecessary, here are other options:

1. Use the Liquibase CLI
Download and extract Liquibase, and directly use the CLI in your deployment scripts or tools like Ansible.

2. Run Liquibase in Docker
Liquibase offers an official Docker image:

bash
Copy code
docker run --rm \
  -v /path/to/changelog:/liquibase/changelog \
  liquibase/liquibase \
  --url=jdbc:postgresql://localhost:5432/student_db \
  --username=postgres \
  --password=strong_password \
  --changeLogFile=/liquibase/changelog/db.changelog-master.yaml update



3. Run the Command Using Ansible
If you're deploying using Ansible, you can add a task to execute the Liquibase command:

Ansible Task
yaml
Copy code
- name: Run Liquibase Migrations
  shell: |
    java -jar /opt/my-app/liquibase/liquibase.jar update
  args:
    executable: /bin/bash
  environment:
    JAVA_HOME: /path/to/java


/////////

you can directly call and interact with Liquibase objects within your Spring application code if you need programmatic control over database migrations. This can be useful in scenarios where you want to trigger migrations manually, execute specific changesets, or perform rollback operations programmatically.

Here’s how you can achieve this:

1. Add Liquibase Dependency
Ensure you have the Liquibase dependency in your pom.xml:

xml
Copy code
<dependency>
    <groupId>org.liquibase</groupId>
    <artifactId>liquibase-core</artifactId>
</dependency>
2. Inject the Liquibase Bean
Spring Boot provides a Liquibase bean by default if you have Liquibase enabled. You can inject this bean into your service or controller class.

Example:
java
Copy code
import liquibase.Liquibase;
import liquibase.exception.LiquibaseException;
import liquibase.resource.ClassLoaderResourceAccessor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;

@Service
public class LiquibaseService {

    @Autowired
    private DataSource dataSource;

    public void runLiquibaseChanges(String changelogPath) {
        try (Connection connection = dataSource.getConnection()) {
            // Create a Liquibase instance
            Liquibase liquibase = new liquibase.Liquibase(
                changelogPath,
                new ClassLoaderResourceAccessor(),
                connection
            );

            // Execute the changeset
            liquibase.update(""); // Empty string means "all contexts"
        } catch (Exception e) {
            e.printStackTrace();
            throw new RuntimeException("Error running Liquibase", e);
        }
    }

    public void rollbackChanges(String rollbackTag) {
        try (Connection connection = dataSource.getConnection()) {
            Liquibase liquibase = new liquibase.Liquibase(
                "db/changelog/db.changelog-master.yaml",
                new ClassLoaderResourceAccessor(),
                connection
            );

            // Rollback to a specific tag
            liquibase.rollback(rollbackTag, "");
        } catch (Exception e) {
            e.printStackTrace();
            throw new RuntimeException("Error rolling back Liquibase changes", e);
        }
    }
}
3. Call Liquibase Programmatically
Now you can call the methods defined in your LiquibaseService class wherever needed. For example:

Example in a Controller:
java
Copy code
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class LiquibaseController {

    @Autowired
    private LiquibaseService liquibaseService;

    @GetMapping("/run-migrations")
    public String runMigrations() {
        liquibaseService.runLiquibaseChanges("db/changelog/db.changelog-master.yaml");
        return "Liquibase migrations executed successfully!";
    }

    @GetMapping("/rollback")
    public String rollback() {
        liquibaseService.rollbackChanges("v1.0"); // Example tag
        return "Liquibase rollback completed!";
    }
}
4. Explanation of Key Components
Changelog Path: The changelogPath (e.g., db/changelog/db.changelog-master.yaml) is the path to your Liquibase changelog file. This can be in YAML, XML, or SQL format.

Contexts: You can pass specific contexts as the second parameter in liquibase.update(context) or liquibase.rollback(tag, context) to run specific sets of changes.

DataSource: The DataSource bean is automatically configured by Spring Boot. This is used to establish a connection to your database.

ClassLoaderResourceAccessor: This is used to load your changelog files from the classpath.

5. Example Use Cases
Conditional Migrations: Run Liquibase migrations only for specific conditions or environments.
Rollback Operations: Rollback specific changes based on user input or application state.
Dynamic Changelogs: Dynamically load and execute different changelogs programmatically.
6. Dependencies Required
Ensure you have the required database driver for Liquibase to work with your database. For example, for PostgreSQL:

xml
Copy code
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
</dependency>
This approach provides flexibility if you need more control over how and when Liquibase runs within your Spring Boot application. Let me know if you need help implementing this!