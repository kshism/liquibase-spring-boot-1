# liquibase-spring-boot



 Liquibase provides an RPM package that you can install on Red Hat-based systems, allowing you to run Liquibase as a shell command. Here's how you can install and set it up:

1. Import the Liquibase Public Key

First, import the Liquibase public key to ensure the authenticity of the package:

bash
```
sudo rpm --import https://repo.liquibase.com/liquibase.asc
```

2. Install yum-utils

Ensure that yum-utils is installed to manage repositories:

bash
```
sudo yum install -y yum-utils
```
3. Add the Liquibase Repository

Add the Liquibase repository to your system:

bash
```
sudo yum-config-manager --add-repo https://repo.liquibase.com/repo-liquibase-com.repo
```
4. Install Liquibase

Now, install Liquibase using yum:

bash
```
sudo yum install liquibase
```
5. Verify the Installation

After installation, verify that Liquibase is installed correctly by checking its version:

bash
```
liquibase --version
```
This should display the installed version of Liquibase, confirming that the installation was successful.

6. Running Liquibase Commands

With Liquibase installed, you can execute commands directly from the shell. For example, to update your database using a changelog file:

bash
```
liquibase --changeLogFile=/path/to/db.changelog-master.yaml update
```
Ensure that you have the necessary database drivers and configurations set up for your specific database.

For more detailed information and additional installation options, refer to the official Liquibase documentation: 

Alternatives to RPM
If creating an RPM seems too complex or unnecessary, here are other options:

1. Use the Liquibase CLI
Download and extract Liquibase, and directly use the CLI in your deployment scripts or tools like Ansible.

2. Run Liquibase in Docker
Liquibase offers an official Docker image:

bash
```bash
docker run --rm \
  -v /path/to/changelog:/liquibase/changelog \
  liquibase/liquibase \
  --url=jdbc:postgresql://localhost:5432/student_db \
  --username=postgres \
  --password=strong_password \
  --changeLogFile=/liquibase/changelog/db.changelog-master.yaml update

```

3. Run the Command Using Ansible
If you're deploying using Ansible, you can add a task to execute the Liquibase command:

Ansible Task
yaml
```yaml
- name: Run Liquibase Migrations
  shell: |
    java -jar /opt/my-app/liquibase/liquibase.jar update
  args:
    executable: /bin/bash
  environment:
    JAVA_HOME: /path/to/java

```
/////////

you can directly call and interact with Liquibase objects within your Spring application code if you need programmatic control over database migrations. This can be useful in scenarios where you want to trigger migrations manually, execute specific changesets, or perform rollback operations programmatically.

Here’s how you can achieve this:

1. Add Liquibase Dependency
Ensure you have the Liquibase dependency in your pom.xml:

xml
```xml
<dependency>
    <groupId>org.liquibase</groupId>
    <artifactId>liquibase-core</artifactId>
</dependency>
```
2. Inject the Liquibase Bean
Spring Boot provides a Liquibase bean by default if you have Liquibase enabled. You can inject this bean into your service or controller class.

Example:
java
```java
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
```
3. Call Liquibase Programmatically
Now you can call the methods defined in your LiquibaseService class wherever needed. For example:

Example in a Controller:
java
```java
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
```
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
```xml
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
</dependency>
```
This approach provides flexibility if you need more control over how and when Liquibase runs within your Spring Boot application. Let me know if you need help implementing this!



/////

To run Liquibase as part of your Maven build goals in a Spring Boot project, you can use the Liquibase Maven Plugin. This allows you to execute database migrations during specific Maven lifecycle phases (e.g., validate, compile, test, install, or deploy) or as a separate Maven goal.

Here’s how you can configure and run Liquibase as a Maven goal:

1. Add the Liquibase Maven Plugin
Add the following Liquibase Maven Plugin configuration to your pom.xml:

xml
```xml
<build>
    <plugins>
        <plugin>
            <groupId>org.liquibase</groupId>
            <artifactId>liquibase-maven-plugin</artifactId>
            <version>4.27.0</version> <!-- Replace with the latest version -->
            <configuration>
                <changeLogFile>src/main/resources/db/changelog/db.changelog-master.yaml</changeLogFile>
                <url>jdbc:postgresql://localhost:5432/student_db</url>
                <username>postgres</username>
                <password>your_password</password>
                <driver>org.postgresql.Driver</driver>
                <defaultSchemaName>public</defaultSchemaName>
                <verbose>true</verbose>
            </configuration>
            <dependencies>
                <!-- PostgreSQL driver -->
                <dependency>
                    <groupId>org.postgresql</groupId>
                    <artifactId>postgresql</artifactId>
                    <version>42.6.0</version> <!-- Replace with the latest version -->
                </dependency>
            </dependencies>
        </plugin>
    </plugins>
</build>
```
2. Add a Liquibase Changelog
Ensure you have a changelog file (db.changelog-master.yaml) in the src/main/resources/db/changelog/ directory. Here's an example changelog:

yaml
```yaml
databaseChangeLog:
  - changeSet:
      id: 1
      author: your_name
      changes:
        - createTable:
            tableName: student
            columns:
              - column:
                  name: id
                  type: BIGINT
                  constraints:
                    primaryKey: true
                    nullable: false
              - column:
                  name: name
                  type: VARCHAR(255)
                  constraints:
                    nullable: false
              - column:
                  name: email
                  type: VARCHAR(255)
                  constraints:
                    nullable: false
              - column:
                  name: created_at
                  type: TIMESTAMP
                  defaultValueComputed: CURRENT_TIMESTAMP
```
3. Run Liquibase Maven Goals
You can now use the Maven plugin to run Liquibase commands.

Update the Database
Run the update goal to apply all pending changes from the changelog to your database:

bash
```bash
mvn liquibase:update
```
Generate a Changelog from an Existing Database
Generate a changelog from the current database schema:

bash
```bash
mvn liquibase:generateChangeLog
```
Validate the Changelog
Validate the syntax and structure of your changelog file:

bash
```
mvn liquibase:validate
```

Rollback Changes
Roll back changes to a specific tag:

bash
```bash
mvn liquibase:rollback -Dliquibase.rollbackTag=1.0
```
4. Integrate Liquibase with Maven Lifecycle
You can configure Liquibase to run automatically during a specific Maven phase, such as install or package. Add the execution block to your Liquibase Maven plugin configuration:

xml
```xml
<execution>
    <phase>process-resources</phase> <!-- You can use validate, compile, or any other phase -->
    <goals>
        <goal>update</goal>
    </goals>
</execution>
```
Updated Plugin Configuration:
xml
```xml
<plugin>
    <groupId>org.liquibase</groupId>
    <artifactId>liquibase-maven-plugin</artifactId>
    <version>4.27.0</version>
    <configuration>
        <changeLogFile>src/main/resources/db/changelog/db.changelog-master.yaml</changeLogFile>
        <url>jdbc:postgresql://localhost:5432/student_db</url>
        <username>postgres</username>
        <password>your_password</password>
        <driver>org.postgresql.Driver</driver>
        <defaultSchemaName>public</defaultSchemaName>
        <verbose>true</verbose>
    </configuration>
    <executions>
        <execution>
            <phase>process-resources</phase>
            <goals>
                <goal>update</goal>
            </goals>
        </execution>
    </executions>
    <dependencies>
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <version>42.6.0</version>
        </dependency>
    </dependencies>
</plugin>
```
With this configuration, Liquibase will automatically apply changes during the process-resources phase of the Maven build lifecycle.

5. Run the Application
When you package and run the Spring Boot application, the database migrations will be executed automatically if the Liquibase Maven plugin is configured to run during a Maven phase.

Example:
bash
```bash
mvn clean install
```
6. Additional Commands
Update SQL (Preview SQL Before Execution):

bash
```bash
mvn liquibase:updateSQL
```
Tag the Database:

bash
```bash
mvn liquibase:tag -Dliquibase.tag=1.0
Drop All Database Objects:
```
bash
```bash
mvn liquibase:dropAll
```
7. Notes
If you’re using a different database, make sure you update the url, driver, and username/password properties in the plugin configuration.
The plugin executes Liquibase commands based on the changelog file specified in the configuration.
By integrating Liquibase as a Maven goal, you ensure database migrations are consistent across environments and can be run as part of your CI/CD pipeline. Let me know if you have additional questions!






