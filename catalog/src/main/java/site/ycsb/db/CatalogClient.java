package site.ycsb.db;

import com.google.api.client.util.Maps;
import com.google.cloud.storage.Storage;
import com.google.cloud.storage.testing.RemoteStorageHelper;
import org.apache.commons.lang3.RandomStringUtils;
import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.Schema;
import org.apache.iceberg.catalog.Namespace;
import org.apache.iceberg.catalog.TableIdentifier;
import org.apache.iceberg.exceptions.AlreadyExistsException;
import org.apache.iceberg.exceptions.CommitFailedException;
import org.apache.iceberg.gcp.GCPProperties;
import org.apache.iceberg.io.FileIOCatalog;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;

import java.io.File;
import java.io.FileInputStream;
import java.util.*;
import static org.apache.iceberg.types.Types.NestedField.required;
import static org.apache.iceberg.types.Types.*;
import org.apache.iceberg.gcp.gcs.GCSFileIO;

public class CatalogClient extends DB {

  private FileIOCatalog catalog;
  private Storage storage;

  static final Schema SCHEMA =
      new Schema(
          required(1, "id", IntegerType.get(), "unique ID"),
          required(2, "data", StringType.get()));

  //static final PartitionSpec SPEC = PartitionSpec.builderFor(SCHEMA).bucket("data", 16).build();

  private Optional<TableIdentifier> getIdentifierFromTableName(String tableName){
    return catalog.listTables(Namespace.empty()).stream()
        .filter(identifier -> identifier.name().equals(tableName))
        .findAny();
  }

  final File credentials() {
    // https://cloud.google.com/docs/authentication/provide-credentials-adc#local-dev
    String location = System.getenv("GOOGLE_APPLICATION_CREDENTIALS");
    if (null == location) {
      location = getProperties().getProperty("gcp.creds");
    }
    if (null == location) {
      throw new IllegalArgumentException("Missing credential location");
    }
    return new File(location);
  }

  @Override
  public void init() throws DBException {
    try (FileInputStream credentials = new FileInputStream(credentials())) {
      storage = RemoteStorageHelper.create("lst-consistency", credentials).getOptions().getService();
    } catch (Exception e){
      throw new DBException("Failed to load credentials");
    }

    try {
      GCSFileIO io = new GCSFileIO(() -> storage, new GCPProperties());
      String warehouseLocation = "gs://benchmarking-ycsb/" + RandomStringUtils.randomAlphanumeric(8);

      final Map<String, String> properties = Maps.newHashMap();
      properties.put(CatalogProperties.WAREHOUSE_LOCATION, warehouseLocation);
      final String location = warehouseLocation + "/catalog";
      catalog = new FileIOCatalog("test", location, null, io, Maps.newHashMap());
      catalog.initialize("YCSB-Bench", properties);

    } catch (Exception e){
      throw new DBException("Failed to load remote / init storage or catalog");
    }

  }


  /**
   * Read a record from the database. Each field/value pair from the result will be stored in a HashMap.
   *
   * @param table The name of the table
   * @param key The record key of the record to read.
   * @param fields The list of fields to read, or null for all of them
   * @param result A HashMap of field/value pairs for the result
   * @return The result of the operation.
   */
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result){
    // we don't care about reads?
    return Status.OK;
  }

  /**
   * Perform a range scan for a set of records in the database. Each field/value pair from the result will be stored
   * in a HashMap.
   *
   * @param table The name of the table
   * @param startkey The record key of the first record to read.
   * @param recordcount The number of records to read
   * @param fields The list of fields to read, or null for all of them
   * @param result A Vector of HashMaps, where each HashMap is a set field/value pairs for one record
   * @return The result of the operation.
   */
  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields,
                              Vector<HashMap<String, ByteIterator>> result){
    // we also don't care about reads...?
    return Status.OK;
  }

  /**
   * Update a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key, overwriting any existing values with the same field name.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @return The result of the operation.
   */
  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    var tid = TableIdentifier.of(Namespace.empty(), key);
    // var tx = catalog.newCreateTableTransaction(tid, SCHEMA);
    try {
      var tx = catalog.buildTable(tid, SCHEMA).createOrReplaceTransaction();
      values.forEach((k, v) -> tx.updateProperties().set(k, v.toString()));
    } catch (CommitFailedException e) {
      return Status.ERROR;
    }
    return Status.OK;
  }

  /**
   * Insert a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key.
   *
   * @param table The name of the table
   * @param key The record key of the record to insert.
   * @param values A HashMap of field/value pairs to insert in the record
   * @return The result of the operation.
   */
  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values){
    var tid = TableIdentifier.of(Namespace.empty(), key);
    try {
      catalog.newCreateTableTransaction(tid, SCHEMA).commitTransaction();
    } catch (CommitFailedException e) {
      return Status.ERROR;
    } catch (AlreadyExistsException e) {
      return Status.BAD_REQUEST;
    }
    return Status.OK;
  }

  /**
   * Delete a record from the database.
   *
   * @param table The name of the table
   * @param key The record key of the record to delete.
   * @return The result of the operation.
   */
  @Override
  public Status delete(String table, String key){
    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);
    if (!tblIdentifier.isPresent()) {
      return Status.BAD_REQUEST;
    }
    if (!catalog.dropTable(tblIdentifier.get())) {
      return Status.ERROR;
    }
    return Status.OK;
  }

}